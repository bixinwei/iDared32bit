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
            var legacy = LegacySwipeTracker()
            var oldPrevious: LegacySwipeContact?
            var oldDisplacement: Float = 0
            var oldStarts = 0
            var oldIdle = 0
            var idle = 0
            var swipe = ControllerSwipeTracker()
            var previous: ControllerSwipeContact?
            var starts = 0
            var moveCount = 0
            var time: Float = 0
            var displacement: Float = 0
            var lastLift: Float?
            for _ in 0..<Int(10 / dt) {
                let old = legacy.sample(anchor: anchor, halfSize: size, delta: velocity * dt, elapsed: dt)
                if let old = old {
                    if let previous = oldPrevious {
                        oldDisplacement += abs(old.point.x - previous.point.x) + abs(old.point.y - previous.point.y)
                    } else { oldStarts += 1 }
                } else { oldIdle += 1 }
                oldPrevious = old
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
                        if let lastLift = lastLift { assert(time - lastLift >= dt - 0.00001, "Lift must occupy a separate guest delivery") }
                        starts += 1
                        moveCount = 0
                    }
                    trace.append("\(name)\t\(time)\t\(contact.point.x)\t\(contact.point.y)\t\(contact.start.x)\t\(contact.start.y)")
                } else {
                    idle += 1
                    if previous != nil {
                        assert(moveCount >= Int((0.1 / dt).rounded(.down)) - 1, "Tiny strokes retain 100ms of movement: \(name)")
                        lastLift = time
                    }
                    trace.append("\(name)\t\(time)\tup")
                }
                previous = contact
                time += dt
            }
            trace.append("\(name)\t\(time)\tup")
            assert(starts >= 4 && displacement > 0.1, "Held stick must restart and keep turning for ten seconds: \(name)")
            assert(displacement >= oldDisplacement * 0.98, "Must not lose sustained displacement: \(name)")
            if name == "held-left" || name == "held-right" || name == "held-up" || name == "held-down" {
                assert(starts < oldStarts, "Normal holds should restart less often: \(name)")
                assert(idle < oldIdle, "Normal holds should lose fewer deliveries: \(name)")
            }
            if name == "held-left-20fps" {
                assert(displacement > oldDisplacement * 1.15, "Low FPS must not inherit a 16-frame speed penalty")
            }
            print("Comparison \(name): new distance=\(displacement), old=\(oldDisplacement), starts=\(starts)/\(oldStarts), idle=\(idle)/\(oldIdle)")
            print("Camera scenario passed: \(name), starts=\(starts), movement=\(displacement)")
        }
        var steady = ControllerSwipeTracker()
        var last: ControllerSwipeContact?
        for _ in 0..<20 {
            let point = steady.sample(anchor: SIMD2(0.5, 0.5), halfSize: SIMD2(0.3, 0.3),
                                      delta: SIMD2(0.005, 0), elapsed: 1 / 60)!
            if let last = last { assert(abs(point.point.x - last.point.x - 0.005) < 0.00001) }
            last = point
        }
        var reversed = ControllerSwipeTracker()
        var prior: ControllerSwipeContact?
        for frame in 0..<600 {
            let sign: Float = (frame / 37) % 2 == 0 ? -1 : 1
            let next = reversed.sample(anchor: SIMD2(0.8, 0.5), halfSize: SIMD2(0.2, 0.3),
                                       delta: SIMD2(sign * 0.02, 0), elapsed: 1 / 60)
            if let next = next, let prior = prior {
                assert((next.point.x - prior.point.x) * sign >= -0.00001)
                assert(next.start == prior.start, "Anchor changes require a lift")
            }
            prior = next
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
