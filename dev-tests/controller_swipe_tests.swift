import Foundation

@main
struct ControllerSwipeTests {
    static func main() throws {
        var trace: [String] = []
        let cases: [(String, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, Float)] = [
            ("held-left", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(-0.6, 0), 1 / 60),
            ("held-right", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(0.6, 0), 1 / 60),
            ("held-up", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(0, -0.9), 1 / 60),
            ("held-down", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(0, 0.9), 1 / 60),
            ("diagonal", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(-0.42, -0.64), 1 / 60),
            ("left-screen-edge", SIMD2(0.02, 0.5), SIMD2(0.2, 0.3), SIMD2(-0.6, 0), 1 / 60),
            ("small-zone-fast", SIMD2(0.72, 0.5), SIMD2(0.016, 0.025), SIMD2(-2, 0), 1 / 60),
            ("held-left-30fps", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(-0.6, 0), 1 / 30),
            ("held-left-20fps", SIMD2(0.72, 0.5), SIMD2(0.2, 0.3), SIMD2(-0.6, 0), 1 / 20)
        ]
        for (name, anchor, size, velocity, dt) in cases {
            var swipe = ControllerSwipeTracker()
            var previous: ControllerSwipeContact?
            var starts = 0
            var moveCount = 0
            var time: Float = 0
            var displacement: Float = 0
            var lastLift: Float?
            for _ in 0..<Int(10 / dt) {
                let contact = swipe.sample(anchor: anchor, halfSize: size, delta: velocity * dt, elapsed: dt)
                if let contact = contact {
                    assert((0.02...0.98).contains(contact.point.x) && (0.02...0.98).contains(contact.point.y))
                    if let previous = previous {
                        let change = contact.point - previous.point
                        assert(change.x * velocity.x >= -0.000001 && change.y * velocity.y >= -0.000001,
                               "A recenter must never be delivered as a reverse drag: \(name)")
                        displacement += abs(change.x) + abs(change.y)
                        moveCount += 1
                    } else {
                        assert(contact.point == contact.start, "Begin must not also move: \(name)")
                        if let lastLift = lastLift { assert(time - lastLift >= 0.02 - 0.00001) }
                        starts += 1
                        moveCount = 0
                    }
                    trace.append("\(name)\t\(time)\t\(contact.point.x)\t\(contact.point.y)\t\(contact.start.x)\t\(contact.start.y)")
                } else {
                    if previous != nil {
                        assert(moveCount >= 15, "Even a tiny, fast stroke needs enough drag deliveries: \(name)")
                        lastLift = time
                    }
                    trace.append("\(name)\t\(time)\tup")
                }
                previous = contact
                time += dt
            }
            trace.append("\(name)\t\(time)\tup")
            assert(starts >= 4 && displacement > 0.1, "Held stick must restart and keep turning for ten seconds: \(name)")
            print("Camera scenario passed: \(name), starts=\(starts), movement=\(displacement)")
        }
        let small = SIMD2<Float>(0.3, 0)
        let linear = ControllerCameraResponse.direction(small, deadzone: 0.15, precise: false)
        let precise = ControllerCameraResponse.direction(small, deadzone: 0.15, precise: true)
        assert(precise.x > 0 && precise.x < linear.x, "Fine aim needs lower center gain")
        assert(ControllerCameraResponse.direction(SIMD2(0.1, 0), deadzone: 0.15, precise: true) == .zero)
        assert(ControllerCameraResponse.direction(SIMD2(-1, 0), deadzone: 0.15, precise: true) == SIMD2(-1, 0))
        var invalid = ControllerSwipeTracker()
        assert(invalid.sample(anchor: SIMD2(0.7, 0.5), halfSize: SIMD2(0.1, 0.2),
                              delta: SIMD2(.nan, 0), elapsed: 1 / 60) == nil)
        if CommandLine.arguments.count > 1 {
            try (trace.joined(separator: "\n") + "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        print("Controller swipe checks passed: nine ten-second holds, separate begin, real lift, restart, edge, small zone, low FPS, response curve, invalid input")
    }
}
