// Feed actual Swift camera output through the production native snapshot
// decoder, guest-coordinate conversion and touch lifecycle. No mirrored mapper.
#[path = "../src/controller_mapping.rs"]
mod mapping;
use mapping::{Change, Snapshot, TouchState};

fn main() {
    let trace = std::fs::read_to_string(std::env::args().nth(1).expect("Swift trace path")).unwrap();
    let mut scenario = String::new();
    let mut state = TouchState::default();
    let mut strokes = 0;
    let mut moves = 0;
    let mut scenarios = 0;
    let mut last_lift: Option<f64> = None;
    let mut began_at: Option<f64> = None;
    for line in trace.lines() {
        let fields: Vec<_> = line.split('\t').collect();
        if fields[0] != scenario {
            if !scenario.is_empty() {
                assert!(strokes >= 4 && moves >= 40, "Camera stalled in {scenario}");
                println!("Guest delivery passed: {scenario}, strokes={strokes}, moves={moves}");
            }
            scenario = fields[0].to_owned();
            scenarios += 1;
            strokes = 0; moves = 0; last_lift = None; began_at = None;
            state = TouchState::default();
        }
        let time: f64 = fields[1].parse().unwrap();
        let mut values = vec![1.0, 0.0, 1.0, 15.0, 0.18, 0.75, 0.18, 0.75];
        if fields[2] != "up" {
            values.push(16.0);
            values.extend(fields[2..].iter().map(|n| n.parse::<f32>().unwrap()));
        }
        // Attack while moving/looking: independent contact must not reset.
        if (time * 2.0) as u64 % 2 == 0 {
            values.extend_from_slice(&[7.0, 0.7, 0.5, 0.7, 0.5]);
        }
        let mut snapshot = Snapshot::decode(&values);
        for contact in &mut snapshot.contacts {
            contact.point = mapping::guest_point(contact.point, (480, 320), [[1.0, 0.0], [0.0, 1.0]]);
            contact.anchor = mapping::guest_point(contact.anchor, (480, 320), [[1.0, 0.0], [0.0, 1.0]]);
        }
        let changes = state.update(snapshot.revision, &snapshot.contacts);
        let camera: Vec<_> = changes.iter().filter(|change| matches!(change,
            Change::Down(16, _) | Change::Move(16, _) | Change::Up(16, _))).collect();
        assert!(camera.len() <= 1, "Camera begin/move/lift collapsed into one guest batch in {scenario}");
        for change in changes {
            match change {
                Change::Down(16, _) => {
                    if let Some(lifted) = last_lift { assert!(time - lifted >= 0.02 - 0.00002); }
                    strokes += 1;
                    began_at = Some(time);
                }
                Change::Move(16, _) => {
                    assert!(time > began_at.expect("Move before Down"));
                    moves += 1;
                }
                Change::Up(16, _) => { last_lift = Some(time); began_at = None; }
                Change::Up(15, _) => panic!("Camera reset released the movement stick"),
                _ => {}
            }
        }
    }
    assert!(strokes >= 4 && moves >= 40);
    println!("Guest delivery passed: {scenario}, strokes={strokes}, moves={moves}");
    assert_eq!(scenarios, 9);
    println!("Swift-to-guest touch checks passed: all nine holds, separate phases, real lift gap, independent movement and fire");
}
