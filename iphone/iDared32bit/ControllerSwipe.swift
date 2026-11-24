/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Accumulate relative drags while a stick stays deflected. After reaching
// the configured area, end one touch before starting a new centered swipe.
struct ControllerSwipeTracker {
    private var point: SIMD2<Float>?
    private var releaseNext = false

    mutating func sample(anchor: SIMD2<Float>, halfSize: SIMD2<Float>, delta: SIMD2<Float>) -> SIMD2<Float>? {
        guard anchor.x.isFinite, anchor.y.isFinite, halfSize.x.isFinite, halfSize.y.isFinite,
              halfSize.x > 0, halfSize.y > 0, delta.x.isFinite, delta.y.isFinite else {
            self = ControllerSwipeTracker()
            return nil
        }
        if releaseNext {
            self = ControllerSwipeTracker()
            return nil
        }
        let low = SIMD2<Float>(max(0.02, anchor.x - halfSize.x), max(0.02, anchor.y - halfSize.y))
        let high = SIMD2<Float>(min(0.98, anchor.x + halfSize.x), min(0.98, anchor.y + halfSize.y))
        let proposed = (point ?? anchor) + delta
        let next = SIMD2<Float>(min(high.x, max(low.x, proposed.x)), min(high.y, max(low.y, proposed.y)))
        point = next
        releaseNext = (delta.x > 0 && next.x >= high.x) || (delta.x < 0 && next.x <= low.x)
            || (delta.y > 0 && next.y >= high.y) || (delta.y < 0 && next.y <= low.y)
        return next
    }
}
