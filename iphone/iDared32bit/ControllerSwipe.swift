/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Camera-look swipe: the right stick drives a continuous drifting touch stroke.
// The stroke never lifts and re-presses at the zone edge; it simply clamps at
// the edge and stays. The touch lifts only when the stick returns to its dead
// zone (the Rust side emits the touch-up when the contact disappears), so there
// is no mid-stroke disconnect while the player is actively aiming.
struct ControllerSwipeContact {
    var point: SIMD2<Float>
    var start: SIMD2<Float>
}

struct ControllerSwipeTracker {
    private var point: SIMD2<Float>?
    private var start = SIMD2<Float>.zero

    mutating func sample(anchor: SIMD2<Float>, halfSize: SIMD2<Float>,
                         delta: SIMD2<Float>, elapsed: Float) -> ControllerSwipeContact? {
        guard anchor.x.isFinite, anchor.y.isFinite, halfSize.x.isFinite, halfSize.y.isFinite,
              halfSize.x > 0, halfSize.y > 0, delta.x.isFinite, delta.y.isFinite else {
            self = ControllerSwipeTracker()
            return nil
        }
        let low = SIMD2<Float>(max(0.02, anchor.x - halfSize.x), max(0.02, anchor.y - halfSize.y))
        let high = SIMD2<Float>(min(0.98, anchor.x + halfSize.x), min(0.98, anchor.y + halfSize.y))
        guard high.x > low.x, high.y > low.y else {
            self = ControllerSwipeTracker()
            return nil
        }
        // Leave a little room inside the zone for both directions near edges.
        let span = high - low
        let innerLow = low + span * 0.05
        let innerHigh = high - span * 0.05
        guard let previous = point else {
            let startPoint = SIMD2<Float>(
                min(high.x - span.x * 0.25, max(low.x + span.x * 0.25, anchor.x)),
                min(high.y - span.y * 0.25, max(low.y + span.y * 0.25, anchor.y)))
            start = startPoint
            point = startPoint
            return ControllerSwipeContact(point: startPoint, start: startPoint)
        }
        let proposed = previous + delta
        let next = SIMD2<Float>(min(innerHigh.x, max(innerLow.x, proposed.x)),
                                min(innerHigh.y, max(innerLow.y, proposed.y)))
        point = next
        return ControllerSwipeContact(point: next, start: start)
    }
}

enum ControllerCameraResponse {
    static func direction(_ stick: SIMD2<Float>, deadzone: Float, precise: Bool) -> SIMD2<Float> {
        let magnitude = (stick.x * stick.x + stick.y * stick.y).squareRoot()
        guard magnitude.isFinite, deadzone.isFinite, magnitude > deadzone else { return .zero }
        let outer = max(deadzone + 0.05, 0.95)
        let strength = min(1, max(0, (magnitude - deadzone) / (outer - deadzone)))
        let response = precise ? strength * strength : strength
        return stick / magnitude * response
    }
}