/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Camera-look swipe. The right stick is a direction + "keep turning": the
// virtual touch drifts at a *constant* speed along that direction. When it
// reaches the zone edge the stroke lifts and immediately re-enters on the
// opposite (trailing) side, so holding the stick keeps swiping the screen
// indefinitely. The lift/re-enter gap is a single delivery, never a positional
// jump.
struct ControllerSwipeContact {
    var point: SIMD2<Float>
    var start: SIMD2<Float>
}

struct ControllerSwipeTracker {
    private var point: SIMD2<Float>?
    private var start = SIMD2<Float>.zero
    private var releaseNext = false
    private var restarting = false

    mutating func sample(anchor: SIMD2<Float>, halfSize: SIMD2<Float>,
                         delta: SIMD2<Float>, elapsed: Float) -> ControllerSwipeContact? {
        guard anchor.x.isFinite, anchor.y.isFinite, halfSize.x.isFinite, halfSize.y.isFinite,
              halfSize.x > 0, halfSize.y > 0, delta.x.isFinite, delta.y.isFinite else {
            self = ControllerSwipeTracker()
            return nil
        }
        // One delivery with no contact lifts the previous stroke; the next
        // call re-enters immediately, so the gap is a single frame.
        if releaseNext {
            point = nil
            releaseNext = false
            restarting = true
            return nil
        }
        let low = SIMD2<Float>(max(0.02, anchor.x - halfSize.x), max(0.02, anchor.y - halfSize.y))
        let high = SIMD2<Float>(min(0.98, anchor.x + halfSize.x), min(0.98, anchor.y + halfSize.y))
        guard high.x > low.x, high.y > low.y else {
            self = ControllerSwipeTracker()
            return nil
        }
        let span = high - low
        let innerLow = low + span * 0.05
        let innerHigh = high - span * 0.05
        guard let previous = point else {
            start = SIMD2<Float>(
                min(high.x - span.x * 0.25, max(low.x + span.x * 0.25, anchor.x)),
                min(high.y - span.y * 0.25, max(low.y + span.y * 0.25, anchor.y)))
            if restarting {
                restarting = false
                // Re-enter toward the trailing side so a sustained stroke gets
                // the maximum room before the next lift.
                let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                if length > 0 {
                    let direction = delta / length
                    for axis in 0..<2 where abs(direction[axis]) > 0.001 {
                        let trailing = direction[axis] > 0
                            ? low[axis] + span[axis] * 0.25
                            : high[axis] - span[axis] * 0.25
                        start[axis] += (trailing - start[axis]) * abs(direction[axis])
                    }
                }
            }
            point = start
            return ControllerSwipeContact(point: start, start: start)
        }
        let proposed = previous + delta
        let next = SIMD2<Float>(min(innerHigh.x, max(innerLow.x, proposed.x)),
                                min(innerHigh.y, max(innerLow.y, proposed.y)))
        point = next
        let epsilon: Float = 0.00001
        releaseNext = (delta.x > 0 && next.x >= innerHigh.x - epsilon)
            || (delta.x < 0 && next.x <= innerLow.x + epsilon)
            || (delta.y > 0 && next.y >= innerHigh.y - epsilon)
            || (delta.y < 0 && next.y <= innerLow.y + epsilon)
        return ControllerSwipeContact(point: next, start: start)
    }
}

enum ControllerCameraResponse {
    static func direction(_ stick: SIMD2<Float>, deadzone: Float, precise: Bool) -> SIMD2<Float> {
        let magnitude = (stick.x * stick.x + stick.y * stick.y).squareRoot()
        guard magnitude.isFinite, deadzone.isFinite, magnitude > deadzone else { return .zero }
        // Constant speed: past the dead zone the screen swipe advances at a
        // steady rate regardless of stick deflection or how fast it was pushed.
        return stick / magnitude
    }
}