/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! Native screen mapper bridge and controller touch lifecycle.
//! Coordinates use the visible game viewport's unit square, excluding bars.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

/// Sample once per guest delivery, at most 60 Hz. Host polling during a slow
/// guest callback must not queue an entire lift/restart before the next frame.
pub struct DeliveryClock {
    requested: bool,
    next_due: Option<Instant>,
}

impl Default for DeliveryClock {
    fn default() -> Self {
        Self { requested: true, next_due: None }
    }
}

impl DeliveryClock {
    pub fn take_sample(&mut self, now: Instant) -> bool {
        if !self.requested || self.next_due.is_some_and(|due| now < due) {
            return false;
        }
        self.requested = false;
        self.next_due = Some(now + Duration::from_secs_f64(1.0 / 60.0));
        true
    }

    /// Called after the guest has consumed the preceding event batch.
    pub fn request(&mut self, now: Instant) -> Instant {
        self.requested = true;
        self.next_due.unwrap_or(now)
    }
}

pub const CONTROL_COUNT: usize = 18;
pub const SNAPSHOT_SIZE: usize = 3 + CONTROL_COUNT * 5;

pub fn guest_point(
    point: (f32, f32),
    size: (u32, u32),
    inverse_rotation: [[f32; 2]; 2],
) -> (f32, f32) {
    let x = point.0 - 0.5;
    let y = point.1 - 0.5;
    let out_x = inverse_rotation[0][0] * x + inverse_rotation[1][0] * y;
    let out_y = inverse_rotation[0][1] * x + inverse_rotation[1][1] * y;
    (
        ((out_x + 0.5) * size.0 as f32).round(),
        ((out_y + 0.5) * size.1 as f32).round(),
    )
}

#[derive(Clone, Copy, Debug)]
pub struct Contact {
    pub id: u8,
    pub point: (f32, f32),
    pub anchor: (f32, f32),
}

#[derive(Default)]
pub struct Snapshot {
    pub capture: bool,
    pub editing: bool,
    pub revision: u32,
    pub contacts: Vec<Contact>,
}

impl Snapshot {
    /// Invalid native data releases contacts rather than injecting bad touches.
    pub fn decode(values: &[f32]) -> Self {
        if values.len() < 3 || (values.len() - 3) % 5 != 0 {
            return Self::default();
        }
        let capture = values[0] == 1.0;
        let editing = values[1] == 1.0;
        let mut snapshot = Self {
            capture,
            editing,
            revision: values[2] as u32,
            ..Self::default()
        };
        if !capture || editing {
            return snapshot;
        }
        let mut ids = [false; CONTROL_COUNT];
        for record in values[3..].chunks_exact(5) {
            if record.iter().any(|v| !v.is_finite())
                || record[0].fract() != 0.0
                || !(0.0..CONTROL_COUNT as f32).contains(&record[0])
                || record[1..].iter().any(|v| !(0.0..=1.0).contains(v))
            {
                continue;
            }
            let id = record[0] as u8;
            if std::mem::replace(&mut ids[id as usize], true) {
                continue;
            }
            snapshot.contacts.push(Contact {
                id,
                point: (record[1], record[2]),
                anchor: (record[3], record[4]),
            });
        }
        snapshot
    }
}

#[derive(Debug, PartialEq)]
pub enum Change {
    Down(u8, (f32, f32)),
    Move(u8, (f32, f32)),
    Up(u8, (f32, f32)),
}

#[derive(Default)]
pub struct TouchState {
    active: BTreeMap<u8, (f32, f32)>,
    revision: u32,
}

impl TouchState {
    /// Points have already been transformed to the guest's portrait coordinates.
    pub fn update(&mut self, revision: u32, contacts: &[Contact]) -> Vec<Change> {
        let mut changes = Vec::new();
        if self.revision != revision {
            changes.extend(self.release());
            self.revision = revision;
        }
        for (&id, &point) in &self.active {
            if !contacts.iter().any(|c| c.id == id) {
                changes.push(Change::Up(id, point));
            }
        }
        self.active
            .retain(|id, _| contacts.iter().any(|c| c.id == *id));
        for contact in contacts {
            match self.active.get(&contact.id) {
                None => {
                    // Floating virtual joysticks need a touch at their center
                    // before dragging to the requested direction.
                    changes.push(Change::Down(contact.id, contact.anchor));
                    if contact.anchor != contact.point {
                        changes.push(Change::Move(contact.id, contact.point));
                    }
                }
                Some(old) if *old != contact.point => {
                    changes.push(Change::Move(contact.id, contact.point));
                }
                Some(_) => {}
            }
            self.active.insert(contact.id, contact.point);
        }
        changes
    }

    pub fn release(&mut self) -> Vec<Change> {
        std::mem::take(&mut self.active)
            .into_iter()
            .map(|(id, point)| Change::Up(id, point))
            .collect()
    }
}

#[cfg(target_os = "ios")]
pub mod native {
    use super::{Snapshot, SNAPSHOT_SIZE};
    use std::ffi::{c_char, CString};
    use std::sync::OnceLock;

    // float buffer: capture, editing, revision; then id,x,y,anchorX,anchorY.
    type PollFn = unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        f32,
        f32,
        f32,
        f32,
        i32,
        *mut f32,
        usize,
    ) -> usize;
    type StopFn = unsafe extern "C" fn();
    static POLL: OnceLock<PollFn> = OnceLock::new();
    static STOP: OnceLock<StopFn> = OnceLock::new();
    type ActivityFn = unsafe extern "C" fn() -> i32;
    static ACTIVITY: OnceLock<ActivityFn> = OnceLock::new();
    static WAIT: OnceLock<StopFn> = OnceLock::new();

    #[no_mangle]
    pub extern "C" fn idared_set_host_activity(activity: ActivityFn, wait: StopFn) {
        let _ = ACTIVITY.set(activity);
        let _ = WAIT.set(wait);
    }

    pub fn host_activity() -> i32 {
        ACTIVITY.get().map_or(0, |activity| unsafe { activity() })
    }

    pub fn wait_for_activity() {
        if let Some(wait) = WAIT.get() {
            unsafe { wait() };
        }
    }

    #[no_mangle]
    pub extern "C" fn idared_set_controller_mapper(poll: PollFn, stop: StopFn) {
        let _ = POLL.set(poll);
        let _ = STOP.set(stop);
    }

    pub fn poll(
        game: &(CString, CString),
        viewport: (f32, f32, f32, f32),
        orientation: i32,
    ) -> Snapshot {
        let Some(poll) = POLL.get() else {
            return Snapshot::default();
        };
        let mut values = [0.0; SNAPSHOT_SIZE];
        let len = unsafe {
            poll(
                game.0.as_ptr(),
                game.1.as_ptr(),
                viewport.0,
                viewport.1,
                viewport.2,
                viewport.3,
                orientation,
                values.as_mut_ptr(),
                values.len(),
            )
        };
        if len > values.len() {
            return Snapshot::default();
        }
        Snapshot::decode(&values[..len])
    }

    pub fn stop() {
        if let Some(stop) = STOP.get() {
            unsafe { stop() };
        }
    }
}

#[cfg(test)]
mod controller_mapping_tests {
    use super::*;
    #[test]
    fn host_polling_cannot_run_ahead_of_guest_delivery() {
        let mut clock = DeliveryClock::default();
        let now = Instant::now();
        assert!(clock.take_sample(now));
        // A long guest frame/callback can yield to host polling many times.
        for tick in 1..120 {
            assert!(!clock.take_sample(now + Duration::from_millis(tick * 10)));
        }
        clock.request(now + Duration::from_secs(2));
        assert!(clock.take_sample(now + Duration::from_secs(2)));
        assert!(!clock.take_sample(now + Duration::from_secs(3)));
    }

    #[test]
    fn guest_delivery_respects_cadence_without_catching_up() {
        let mut clock = DeliveryClock::default();
        let now = Instant::now();
        assert!(clock.take_sample(now));
        let due = clock.request(now);
        assert!(!clock.take_sample(now + Duration::from_millis(8)));
        assert!(clock.take_sample(due));
        let late = now + Duration::from_secs(2);
        clock.request(late);
        assert!(clock.take_sample(late));
        assert_eq!(clock.request(late), late + Duration::from_secs_f64(1.0 / 60.0));
        assert!(!clock.take_sample(late));
    }

    fn button(id: u8, point: (f32, f32)) -> Contact {
        Contact {
            id,
            point,
            anchor: point,
        }
    }

    #[test]
    fn viewport_points_rotate_to_guest_in_all_orientations() {
        let point = (0.2, 0.7);
        let size = (320, 480);
        assert_eq!(
            guest_point(point, size, [[1.0, 0.0], [0.0, 1.0]]),
            (64.0, 336.0)
        );
        assert_eq!(
            guest_point(point, size, [[-1.0, 0.0], [0.0, -1.0]]),
            (256.0, 144.0)
        );
        assert_eq!(
            guest_point(point, size, [[0.0, 1.0], [-1.0, 0.0]]),
            (96.0, 96.0)
        );
        assert_eq!(
            guest_point(point, size, [[0.0, -1.0], [1.0, 0.0]]),
            (224.0, 384.0)
        );
    }

    #[test]
    fn movement_and_fire_are_independent_multitouches() {
        let mut state = TouchState::default();
        let movement = Contact {
            id: 15,
            point: (80.0, 200.0),
            anchor: (60.0, 200.0),
        };
        let fire = button(0, (280.0, 300.0));
        assert_eq!(
            state.update(0, &[movement, fire]),
            vec![
                Change::Down(15, movement.anchor),
                Change::Move(15, movement.point),
                Change::Down(0, fire.point)
            ]
        );
        assert_eq!(
            state.update(0, &[movement]),
            vec![Change::Up(0, fire.point)]
        );
        assert!(state.update(0, &[movement]).is_empty());
        assert_eq!(state.update(0, &[]), vec![Change::Up(15, movement.point)]);
    }

    #[test]
    fn profile_change_ends_old_touch_before_new_position() {
        let mut state = TouchState::default();
        state.update(1, &[button(0, (10.0, 20.0))]);
        assert_eq!(
            state.update(2, &[button(0, (100.0, 200.0))]),
            vec![Change::Up(0, (10.0, 20.0)), Change::Down(0, (100.0, 200.0))]
        );
    }

    #[test]
    fn cursor_click_drags_and_releases_at_last_cursor_position() {
        let mut state = TouchState::default();
        assert_eq!(
            state.update(1, &[button(6, (200.0, 100.0))]),
            vec![Change::Down(6, (200.0, 100.0))]
        );
        assert_eq!(
            state.update(1, &[button(6, (240.0, 180.0))]),
            vec![Change::Move(6, (240.0, 180.0))]
        );
        assert_eq!(state.update(1, &[]), vec![Change::Up(6, (240.0, 180.0))]);
    }

    #[test]
    fn editing_disabling_and_disconnect_release_held_touches() {
        let mut state = TouchState::default();
        for values in [
            vec![1.0, 1.0, 0.0],
            vec![0.0, 0.0, 0.0],
            vec![1.0, 0.0, 0.0],
        ] {
            state.update(0, &[button(0, (10.0, 20.0))]);
            let snapshot = Snapshot::decode(&values);
            assert_eq!(
                state.update(snapshot.revision, &snapshot.contacts),
                vec![Change::Up(0, (10.0, 20.0))]
            );
            assert!(state.release().is_empty());
        }
    }

    #[test]
    fn invalid_and_duplicate_contacts_cannot_inject_touches() {
        let values = [
            1.0,
            0.0,
            1.0,
            0.0,
            0.3,
            0.4,
            0.3,
            0.4,
            0.0,
            0.8,
            0.8,
            0.8,
            0.8,
            1.0,
            f32::NAN,
            0.3,
            0.3,
            0.3,
            18.0,
            0.3,
            0.3,
            0.3,
            0.3,
            2.0,
            1.1,
            0.2,
            0.2,
            0.2,
        ];
        let contacts = Snapshot::decode(&values).contacts;
        assert_eq!(contacts.len(), 1);
        assert_eq!(contacts[0].point, (0.3, 0.4));
        assert!(Snapshot::decode(&values[..4]).contacts.is_empty());
    }
}
