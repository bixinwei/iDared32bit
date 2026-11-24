/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Independently implemented camera strokes. Design references (no code copied):
// github.com/PlayCover/PlayTools: SwipeAction and ThumbstickCursorControl.
// github.com/kinou-p/android-open-mapper: CameraProcessor.
// A begin occupies its own guest delivery; edge resets include a real lift.
struct ControllerSwipeContact {
    var point: SIMD2<Float>
    var start: SIMD2<Float>
}

struct ControllerSwipeTracker {
    private var point: SIMD2<Float>?
    private var start = SIMD2<Float>.zero
    private var releaseNext = false
    private var cooldown: Float = 0
    private var moves = 0

    mutating func sample(anchor: SIMD2<Float>, halfSize: SIMD2<Float>,
                         delta: SIMD2<Float>, elapsed: Float) -> ControllerSwipeContact? {
        guard anchor.x.isFinite, anchor.y.isFinite, halfSize.x.isFinite, halfSize.y.isFinite,
              halfSize.x > 0, halfSize.y > 0, delta.x.isFinite, delta.y.isFinite,
              elapsed.isFinite, elapsed >= 0 else {
            self = ControllerSwipeTracker()
            return nil
        }
        if cooldown > 0 {
            cooldown = max(0, cooldown - elapsed)
            if cooldown > 0 { return nil }
        }
        if releaseNext {
            point = nil
            releaseNext = false
            cooldown = 0.020
            moves = 0
            return nil
        }
        let low = SIMD2<Float>(max(0.02, anchor.x - halfSize.x), max(0.02, anchor.y - halfSize.y))
        let high = SIMD2<Float>(min(0.98, anchor.x + halfSize.x), min(0.98, anchor.y + halfSize.y))
        guard high.x > low.x, high.y > low.y else { self = ControllerSwipeTracker(); return nil }
        // Leave room inside the zone for both directions even near screen edges.
        let span = high - low
        let innerLow = low + span * 0.05
        let innerHigh = high - span * 0.05
        guard let previous = point else {
            start = SIMD2<Float>(min(high.x - span.x * 0.25, max(low.x + span.x * 0.25, anchor.x)),
                                 min(high.y - span.y * 0.25, max(low.y + span.y * 0.25, anchor.y)))
            point = start
            return ControllerSwipeContact(point: start, start: start)
        }
        // Keep short/high-sensitivity strokes recognizable as drags. Uniform
        // vector scaling preserves diagonals while reserving 16 movement steps.
        var scale: Float = 1
        let remaining = Float(max(1, 16 - moves))
        for axis in 0..<2 where delta[axis] != 0 {
            let available = delta[axis] > 0 ? innerHigh[axis] - previous[axis] : previous[axis] - innerLow[axis]
            scale = min(scale, max(0, available) / (abs(delta[axis]) * remaining))
        }
        let proposed = previous + delta * scale
        let next = SIMD2<Float>(min(innerHigh.x, max(innerLow.x, proposed.x)),
                                min(innerHigh.y, max(innerLow.y, proposed.y)))
        point = next
        moves += 1
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
        let outer = max(deadzone + 0.05, 0.95)
        let strength = min(1, max(0, (magnitude - deadzone) / (outer - deadzone)))
        let response = precise ? strength * strength : strength
        return stick / magnitude * response
    }
}
