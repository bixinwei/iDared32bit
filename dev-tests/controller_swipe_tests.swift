@main
struct ControllerSwipeTests {
    static func main() {
        let anchor = SIMD2<Float>(0.7, 0.5)
        let size = SIMD2<Float>(0.1, 0.2)
        var swipe = ControllerSwipeTracker()
        let first = swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(0.02, 0))!
        let second = swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(0.02, 0))!
        assert(second.x > first.x, "A held stick must keep moving the touch")
        let edge = swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(1, 0))!
        assert(abs(edge.x - 0.8) < 0.0001 && edge.y == 0.5, "Drag must remain inside the area")
        assert(swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(0.02, 0)) == nil,
               "The previous touch must end before recentering")
        let restarted = swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(0.02, 0))!
        assert(abs(restarted.x - first.x) < 0.0001, "Next drag must restart at the anchor")
        swipe = ControllerSwipeTracker()
        let upward = swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(0, -0.03))!
        assert(upward.x == 0.7 && upward.y < 0.5, "Vertical movement must remain independent")
        assert(swipe.sample(anchor: anchor, halfSize: size, delta: SIMD2<Float>(.nan, 0)) == nil,
               "Invalid input must end the touch")
        print("Controller swipe checks passed: continuous movement, bounds, release, restart, vertical axis, invalid input")
    }
}
