/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Game-specific controller-to-screen mapping. No synthetic UIKit events:
// Rust receives a snapshot and delivers independent guest UITouch lifecycles.
import GameController
import UIKit

private struct ScreenBinding: Codable {
    var control: Int
    var x: Float
    var y: Float
    /// Joystick radius as a fraction of the viewport's shorter side.
    var radius: Float = 0.12
    var cursorClick: Bool?
    var swipe: ScreenSwipe?
}

private struct ScreenSwipe: Codable {
    var speed: Float = 0.9
    var invertY = false
    var cursorWithL1 = false
    var precise: Bool?
}

private struct ScreenCursor: Codable {
    var enabled = true
    var speed: Float = 0.8
}

private struct ScreenProfile: Codable {
    var enabled = false
    var deadzone: Float = 0.15
    var bindings: [ScreenBinding] = []
    var cursor: ScreenCursor?
}

private struct ScreenConfiguration: Codable {
    var version = 2
    var portrait = ScreenProfile()
    var landscape = ScreenProfile()
}

private let controlNames = [
    "A / ×", "B / ○", "X / □", "Y / △", "LB", "RB",
    "LT", "RT", "L3", "R3", "Start / Options",
    "方向键 ←", "方向键 ↑", "方向键 →", "方向键 ↓",
    "左摇杆", "右摇杆", "十字键摇杆"
]
private let shortControlNames = [
    "A", "B", "X", "Y", "LB", "RB", "LT", "RT", "L3", "R3", "Start",
    "←", "↑", "→", "↓", "左摇杆", "右摇杆", "十字键"
]

private enum ScreenMapper {
    // Called only on SDL's main thread, except stop() which hops to that thread.
    nonisolated(unsafe) static var session: MappingSession?
}

private enum HostActivity {
    nonisolated(unsafe) static var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) static var inactive = false
    nonisolated(unsafe) static var terminating = false
}

@_cdecl("idared_install_host_activity")
public func idaredInstallHostActivity() {
    guard HostActivity.observers.isEmpty else { return }
    let center = NotificationCenter.default
    HostActivity.observers = [
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            HostActivity.inactive = true
            ScreenMapper.session?.waitingForNeutral = true
        },
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            HostActivity.inactive = false
        },
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            HostActivity.terminating = true
        }
    ]
}

@_cdecl("idared_host_activity_state")
public func idaredHostActivityState() -> Int32 {
    if HostActivity.terminating { return 2 }
    return (HostActivity.inactive || UIApplication.shared.applicationState != .active) ? 1 : 0
}

@_cdecl("idared_host_activity_wait")
public func idaredHostActivityWait() {
    // Keep UIKit processing notification-center dismissal / foreground events
    // while the guest CPU and mixer are paused. Never draw OpenGL in background.
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}

@_cdecl("idared_controller_mapper_poll")
public func idaredControllerMapperPoll(
    _ gameID: UnsafePointer<CChar>, _ gameName: UnsafePointer<CChar>,
    _ vx: Float, _ vy: Float, _ vw: Float, _ vh: Float, _ orientation: Int32,
    _ output: UnsafeMutablePointer<Float>, _ capacity: Int
) -> Int {
    guard Thread.isMainThread, capacity >= 3 else { return 0 }
    let id = String(cString: gameID)
    if ScreenMapper.session?.gameID != id {
        ScreenMapper.session?.stop()
        ScreenMapper.session = MappingSession(gameID: id, name: String(cString: gameName))
    }
    guard let session = ScreenMapper.session else { return 0 }
    session.updateViewport(CGRect(x: CGFloat(vx), y: CGFloat(vy),
                                 width: CGFloat(vw), height: CGFloat(vh)), orientation: orientation)
    let contacts = session.contacts()
    output[0] = (session.profile.enabled || session.editing) ? 1 : 0
    output[1] = session.editing ? 1 : 0
    output[2] = Float(session.revision)
    var count = 3
    for contact in contacts where count + 5 <= capacity {
        for value in contact { output[count] = value; count += 1 }
    }
    return count
}

@_cdecl("idared_controller_mapper_stop")
public func idaredControllerMapperStop() {
    if Thread.isMainThread {
        ScreenMapper.session?.stop()
        ScreenMapper.session = nil
    } else {
        DispatchQueue.main.async {
            ScreenMapper.session?.stop()
            ScreenMapper.session = nil
        }
    }
}

private final class MappingSession {
    let gameID: String
    let gameName: String
    let file: URL
    var configuration: ScreenConfiguration
    var saved: ScreenConfiguration
    var landscape = false
    var orientation: Int32 = -1
    var editing = false
    var selected = 0
    var placingSelected = false
    // Selection refers to an individual mapping, independently of its physical key.
    var selectedBinding: Int?
    var selectedIndex: Int? {
        guard let index = selectedBinding, profile.bindings.indices.contains(index),
              profile.bindings[index].control == selected else { return nil }
        return index
    }
    var selectedMapping: ScreenBinding? { selectedIndex.map { profile.bindings[$0] } }
    var revision: UInt32 = 1
    var waitingForNeutral = true
    var lastController: ObjectIdentifier?
    var fractions = CGRect.zero
    var window: MappingWindow?
    var controller: MappingViewController?
    weak var gameView: UIView?
    var status = ""
    var cursorPoint = CGPoint(x: 0.7, y: 0.5)
    var cursorHeld = false
    var lastSampleTime = ProcessInfo.processInfo.systemUptime
    var swipeTrackers: [Int: ControllerSwipeTracker] = [:]
    var runtimeCursorVisible = false
    var isDeadSpace: Bool { gameID.lowercased().hasPrefix("com.ea.deadspace") }
    var profile: ScreenProfile {
        get { landscape ? configuration.landscape : configuration.portrait }
        set {
            if landscape { configuration.landscape = newValue }
            else { configuration.portrait = newValue }
        }
    }

    init(gameID: String, name: String) {
        self.gameID = gameID
        self.gameName = name
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ControllerMappings", isDirectory: true)
        let filename = Data(gameID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        file = folder.appendingPathComponent(filename + ".json")
        if let data = try? Data(contentsOf: file),
           var loaded = try? JSONDecoder().decode(ScreenConfiguration.self, from: data),
           (1...2).contains(loaded.version) {
            loaded.portrait = Self.validated(loaded.portrait)
            loaded.landscape = Self.validated(loaded.landscape)
            if loaded.version == 1 {
                loaded.portrait = Self.upgradedCamera(loaded.portrait)
                loaded.landscape = Self.upgradedCamera(loaded.landscape)
                loaded.version = 2
            }
            configuration = loaded
        } else {
            configuration = ScreenConfiguration()
            if gameID.lowercased().hasPrefix("com.ea.deadspace") {
                // Starting layout, not a claim about every level's controls.
                // LB temporarily selects the cursor for contextual targets.
                configuration.landscape = Self.deadSpaceProfile()
            }
        }
        saved = configuration
    }

    static func validated(_ input: ScreenProfile) -> ScreenProfile {
        var result = input
        result.deadzone = input.deadzone.isFinite ? min(0.5, max(0.05, input.deadzone)) : 0.15
        if var cursor = result.cursor {
            cursor.speed = cursor.speed.isFinite ? min(2, max(0.2, cursor.speed)) : 0.8
            result.cursor = cursor
        }
        result.bindings = input.bindings.filter {
            (0..<18).contains($0.control) && $0.x.isFinite && $0.y.isFinite
                && (0...1).contains($0.x) && (0...1).contains($0.y)
                && $0.radius.isFinite && (0.025...0.3).contains($0.radius)
        }
        result.bindings = Array(result.bindings.prefix(64)).map { binding in
            var binding = binding
            if var swipe = binding.swipe {
                swipe.speed = swipe.speed.isFinite ? min(3, max(0.2, swipe.speed)) : 0.9
                binding.swipe = binding.control >= 15 ? swipe : nil
            }
            return binding
        }
        return result
    }

    static func deadSpaceProfile() -> ScreenProfile {
        ScreenProfile(enabled: true, deadzone: 0.15, bindings: [
            ScreenBinding(control: 15, x: 0.18, y: 0.75, radius: 0.14),
            ScreenBinding(control: 16, x: 0.72, y: 0.5, radius: 0.3, swipe: ScreenSwipe()),
            ScreenBinding(control: 7, x: 0.7, y: 0.5, cursorClick: true)
        ], cursor: ScreenCursor(enabled: false))
    }

    static func upgradedCamera(_ input: ScreenProfile) -> ScreenProfile {
        var p = input
        if p.cursor?.enabled != true,
           let index = p.bindings.firstIndex(where: { $0.control == 16 }) {
            // The requested right-stick role is camera look. Keep the saved
            // center; explicit virtual-joystick mode remains selectable.
            if p.bindings[index].swipe == nil { p.bindings[index].swipe = ScreenSwipe() }
            p.bindings[index].radius = max(0.3, p.bindings[index].radius)
        }
        return p
    }

    func changed() {
        // Bound to exactly representable Float integers in the C snapshot.
        revision = revision % 16_000_000 + 1
        waitingForNeutral = true
        swipeTrackers.removeAll()
        runtimeCursorVisible = false
        controller?.refresh()
    }

    func stop() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        controller = nil
    }

    func updateViewport(_ fractions: CGRect, orientation: Int32) {
        if self.orientation != orientation {
            self.orientation = orientation
            self.landscape = orientation >= 2
            status = "横屏和竖屏分别保存映射"
            selectedBinding = nil
            controller?.resetOverlayLayout()
            changed()
        }
        self.fractions = fractions
        if window == nil {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }),
                  let sdlClass = NSClassFromString("SDL_uikitviewcontroller"),
                  let source = scene.windows.first(where: {
                      $0.rootViewController?.isKind(of: sdlClass) == true
                  }), let root = source.rootViewController else { return }
            gameView = root.view
            let overlay = MappingWindow(windowScene: scene)
            overlay.frame = source.frame
            overlay.windowLevel = UIWindow.Level(rawValue: source.windowLevel.rawValue + 0.5)
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            let vc = MappingViewController(session: self, gameController: root)
            overlay.rootViewController = vc
            overlay.session = self
            window = overlay
            controller = vc
            // Keep SDL's window key; a key overlay can steal controller input.
            overlay.isHidden = false
        }
        controller?.updateViewport()
    }

    func beginEditing() {
        editing = true
        selectedBinding = nil
        status = "点按键添加新位置；同一键可重复添加，按下时同时触发"
        changed()
    }

    func finish(save: Bool) {
        if save {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(configuration).write(to: file, options: .atomic)
                saved = configuration
            } catch {
                status = "保存失败：\(error.localizedDescription)"
                controller?.refresh()
                return
            }
        } else {
            configuration = saved
        }
        editing = false
        status = ""
        changed()
    }

    func place(at point: CGPoint, viewport: CGRect) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let x = Float(min(0.98, max(0.02, (point.x - viewport.minX) / viewport.width)))
        let y = Float(min(0.98, max(0.02, (point.y - viewport.minY) / viewport.height)))
        var p = profile
        if selected == 16, var cursor = p.cursor { cursor.enabled = false; p.cursor = cursor }
        if selected == 17 { p.bindings.removeAll { (11...14).contains($0.control) } }
        else if (11...14).contains(selected) { p.bindings.removeAll { $0.control == 17 } }
        if let index = selectedIndex {
            p.bindings[index].x = x
            p.bindings[index].y = y
        } else {
            guard p.bindings.count < 64 else {
                status = "当前方向最多保存 64 个映射点"; controller?.refresh(); return
            }
            selectedBinding = p.bindings.count
            p.bindings.append(ScreenBinding(control: selected, x: x, y: y,
                radius: selected == 16 ? 0.3 : 0.12, swipe: selected == 16 ? ScreenSwipe() : nil))
        }
        p.enabled = true
        profile = p
        changed()
    }

    func contacts() -> [[Float]] {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.05, max(0, now - lastSampleTime)))
        lastSampleTime = now
        if cursorHeld { cursorHeld = false; controller?.canvas.setNeedsDisplay() }
        let connected = GCController.controllers().first { $0.extendedGamepad != nil }
        let identity = connected.map { ObjectIdentifier($0) }
        if lastController != identity {
            lastController = identity
            waitingForNeutral = true
            changed()
        }
        let connection = connected?.vendorName ?? "未连接手柄"
        controller?.setConnection(connection)
        guard let pad = connected?.extendedGamepad else { return [] }
        let buttons: [Float] = [
            pad.buttonA.value, pad.buttonB.value, pad.buttonX.value, pad.buttonY.value,
            pad.leftShoulder.value, pad.rightShoulder.value,
            pad.leftTrigger.value, pad.rightTrigger.value,
            pad.leftThumbstickButton?.value ?? 0, pad.rightThumbstickButton?.value ?? 0,
            pad.buttonMenu.value, pad.dpad.left.value, pad.dpad.up.value,
            pad.dpad.right.value, pad.dpad.down.value
        ]
        let sticks: [(Float, Float)] = [
            (pad.leftThumbstick.xAxis.value, -pad.leftThumbstick.yAxis.value),
            (pad.rightThumbstick.xAxis.value, -pad.rightThumbstick.yAxis.value),
            (pad.dpad.xAxis.value, -pad.dpad.yAxis.value)
        ]
        let neutral = buttons.allSatisfy { $0 < 0.25 }
            && sticks.allSatisfy { hypotf($0.0, $0.1) <= profile.deadzone }
        if waitingForNeutral {
            swipeTrackers.removeAll()
            if neutral { waitingForNeutral = false }
            return []
        }
        guard profile.enabled, !editing, UIApplication.shared.applicationState == .active,
              let canvas = controller?.canvas, canvas.viewport.width > 0,
              canvas.viewport.height > 0 else {
            waitingForNeutral = true
            swipeTrackers.removeAll()
            return []
        }
        let viewport = canvas.viewport
        let shorter = Float(min(viewport.width, viewport.height))
        let cameraBinding = profile.bindings.first { $0.control == 16 && $0.swipe != nil }
        let temporaryCursor = cameraBinding?.swipe?.cursorWithL1 == true && buttons[4] >= 0.25
            && !profile.bindings.contains { $0.control == 4 }
        let cursorActive = profile.cursor?.enabled == true || temporaryCursor
        if runtimeCursorVisible != cursorActive {
            runtimeCursorVisible = cursorActive
            controller?.updateModeLabel()
            canvas.setNeedsDisplay()
        }
        if cursorActive {
            let (x, y) = sticks[1]
            let magnitude = hypotf(x, y)
            if magnitude > profile.deadzone {
                let speed = (min(1, magnitude) - profile.deadzone) / (1 - profile.deadzone)
                    * (profile.cursor?.speed ?? 0.8) * shorter * dt
                cursorPoint.x = min(1, max(0, cursorPoint.x + CGFloat(x / magnitude * speed / Float(viewport.width))))
                cursorPoint.y = min(1, max(0, cursorPoint.y + CGFloat(y / magnitude * speed / Float(viewport.height))))
                canvas.setNeedsDisplay()
            }
        }
        var result: [[Float]] = []
        for (mappingID, binding) in profile.bindings.enumerated() {
            if binding.control < 15 {
                if binding.control == 4 && temporaryCursor { continue }
                if buttons[binding.control] >= 0.25 {
                    if binding.cursorClick == true {
                        guard cursorActive || cameraBinding != nil else { continue }
                        let x = cursorActive ? Float(cursorPoint.x) : cameraBinding!.x
                        let y = cursorActive ? Float(cursorPoint.y) : cameraBinding!.y
                        result.append([Float(mappingID), x, y, x, y])
                        cursorHeld = true
                        canvas.setNeedsDisplay()
                    } else {
                        result.append([Float(mappingID), binding.x, binding.y, binding.x, binding.y])
                    }
                }
            } else {
                if binding.control == 16 && cursorActive {
                    swipeTrackers.removeValue(forKey: mappingID)
                    continue
                }
                let (x, y) = sticks[binding.control - 15]
                let magnitude = hypotf(x, y)
                guard magnitude > profile.deadzone else {
                    swipeTrackers.removeValue(forKey: mappingID)
                    continue
                }
                let distance = (min(1, magnitude) - profile.deadzone) / (1 - profile.deadzone)
                let radius = binding.radius * shorter
                if let swipe = binding.swipe {
                    let direction = ControllerCameraResponse.direction(SIMD2<Float>(x, y),
                        deadzone: profile.deadzone, precise: swipe.precise != false)
                    let speed = swipe.speed * shorter * dt
                    let delta = SIMD2<Float>(direction.x * speed / Float(viewport.width),
                        direction.y * speed / Float(viewport.height) * (swipe.invertY ? -1 : 1))
                    var tracker = swipeTrackers[mappingID] ?? ControllerSwipeTracker()
                    let contact = tracker.sample(anchor: SIMD2<Float>(binding.x, binding.y),
                        halfSize: SIMD2<Float>(radius / Float(viewport.width), radius / Float(viewport.height)),
                        delta: delta, elapsed: dt)
                    swipeTrackers[mappingID] = tracker
                    if let contact = contact {
                        result.append([Float(mappingID), contact.point.x, contact.point.y,
                                       contact.start.x, contact.start.y])
                    }
                    continue
                }
                let px = binding.x + x / magnitude * distance * radius / Float(viewport.width)
                let py = binding.y + y / magnitude * distance * radius / Float(viewport.height)
                result.append([Float(mappingID), min(1, max(0, px)), min(1, max(0, py)),
                               binding.x, binding.y])
            }
        }
        return result
    }
}

private final class MappingWindow: UIWindow {
    weak var session: MappingSession?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if session?.editing != true && (hit === rootViewController?.view || hit is MappingCanvas) {
            return nil
        }
        return hit
    }
}

private final class MappingViewController: UIViewController {
    unowned let session: MappingSession
    weak var gameController: UIViewController?
    let canvas = MappingCanvas()
    let open = UIButton(type: .system)
    let panel = UIView()
    let titleLabel = UILabel()
    let connection = UILabel()
    let hint = UILabel()
    let selectedLabel = UILabel()
    let enabled = UISwitch()
    let radius = UISlider()
    let radiusLabel = UILabel()
    let deadzone = UISlider()
    let deadzoneLabel = UILabel()
    let targetMode = UISegmentedControl(items: ["固定位置", "游标点击"])
    let stickMode = UISegmentedControl(items: ["虚拟摇杆", "视角滑动", "游标"])
    let cursorEnabled = UISwitch()
    let cursorLabel = UILabel()
    let cursorSpeed = UISlider()
    let cursorSpeedLabel = UILabel()
    let stickControls = UISegmentedControl(items: ["⊕ 左摇杆", "⊕ 右摇杆"])
    let dragHandle = UILabel()
    let keysLabel = UILabel()
    var openPosition: CGPoint?
    var panelPosition: CGPoint?
    var panOrigin = CGPoint.zero
    weak var dragSurface: UIView?
    let settingsScroll = UIScrollView()
    let settingsContent = UIView()
    let placementHint = UILabel()
    let invertYLabel = UILabel()
    let invertY = UISwitch()
    let cursorModifierLabel = UILabel()
    let cursorModifier = UISwitch()
    let responseLabel = UILabel()
    let responseMode = UISegmentedControl(items: ["线性", "精细瞄准"])
    let modeLabel = UILabel()
    var choiceButtons: [UIButton] = []
    var controlsCollapsed = false

    init(session: MappingSession, gameController: UIViewController) {
        self.session = session
        self.gameController = gameController
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        gameController?.supportedInterfaceOrientations ?? .all
    }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        canvas.session = session
        view.addSubview(canvas)
        configure(open, "手柄", action: #selector(edit))
        open.setImage(UIImage(systemName: "gamecontroller.fill"), for: .normal)
        open.backgroundColor = UIColor(red: 0.08, green: 0.14, blue: 0.24, alpha: 0.94)
        open.tintColor = .white
        open.layer.borderWidth = 1
        open.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.7).cgColor
        open.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragOverlay(_:))))
        open.setTitleColor(.white, for: .normal)
        open.layer.cornerRadius = 24
        open.accessibilityLabel = "编辑手柄屏幕映射"
        view.addSubview(open)
        placementHint.font = .systemFont(ofSize: 12, weight: .semibold)
        placementHint.textColor = .white
        placementHint.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        placementHint.numberOfLines = 2
        placementHint.layer.cornerRadius = 8
        placementHint.clipsToBounds = true
        view.addSubview(placementHint)
        modeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modeLabel.textColor = .white
        modeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        modeLabel.textAlignment = .center
        modeLabel.layer.cornerRadius = 8
        modeLabel.clipsToBounds = true
        view.addSubview(modeLabel)
        panel.overrideUserInterfaceStyle = .dark
        panel.backgroundColor = UIColor(red: 0.055, green: 0.08, blue: 0.13, alpha: 0.97)
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
        dragHandle.text = "⠿ 拖动面板 · 按键映射"
        dragHandle.textAlignment = .center
        dragHandle.font = .systemFont(ofSize: 12, weight: .semibold)
        dragHandle.textColor = .secondaryLabel
        dragHandle.isUserInteractionEnabled = true
        dragHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragOverlay(_:))))
        panel.addSubview(dragHandle)
        keysLabel.text = "添加按键 · 可重复添加同一个键"
        keysLabel.font = .systemFont(ofSize: 11, weight: .medium)
        keysLabel.textColor = .secondaryLabel
        panel.addSubview(keysLabel)
        panel.layer.cornerRadius = 16
        view.addSubview(panel)
        panel.addSubview(settingsScroll)
        settingsScroll.addSubview(settingsContent)
        settingsScroll.alwaysBounceVertical = true
        settingsScroll.showsVerticalScrollIndicator = true
        for label in [titleLabel, connection, hint, selectedLabel, radiusLabel, deadzoneLabel, cursorLabel, cursorSpeedLabel, invertYLabel, cursorModifierLabel, responseLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .label
            if label === titleLabel || label === connection { panel.addSubview(label) }
            else { settingsContent.addSubview(label) }
        }
        titleLabel.font = .boldSystemFont(ofSize: 14)
        hint.numberOfLines = 2
        hint.font = .systemFont(ofSize: 11)
        panel.addSubview(enabled)
        enabled.addTarget(self, action: #selector(toggleEnabled), for: .valueChanged)
        panel.addSubview(stickControls)
        stickControls.addTarget(self, action: #selector(selectStick), for: .valueChanged)
        for index in [0, 1, 2, 3, 4, 6, 5, 7] {
            let name = shortControlNames[index]
            let button = UIButton(type: .system)
            button.tag = index
            configure(button, name, action: #selector(selectControl(_:)))
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
            button.layer.cornerRadius = 18
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.4).cgColor
            panel.addSubview(button)
            choiceButtons.append(button)
        }
        radius.minimumValue = 0.025
        radius.maximumValue = 0.3
        radius.addTarget(self, action: #selector(changeRadius), for: .valueChanged)
        settingsContent.addSubview(radius)
        deadzone.minimumValue = 0.05
        deadzone.maximumValue = 0.5
        deadzone.addTarget(self, action: #selector(changeDeadzone), for: .valueChanged)
        settingsContent.addSubview(deadzone)
        settingsContent.addSubview(targetMode)
        targetMode.addTarget(self, action: #selector(changeTarget), for: .valueChanged)
        settingsContent.addSubview(stickMode)
        stickMode.addTarget(self, action: #selector(changeStickMode), for: .valueChanged)
        invertYLabel.text = "反转视角纵向"
        settingsContent.addSubview(invertY)
        invertY.addTarget(self, action: #selector(changeInvertY), for: .valueChanged)
        cursorModifierLabel.text = "未映射 LB 时，按住切换游标"
        settingsContent.addSubview(cursorModifier)
        cursorModifier.addTarget(self, action: #selector(changeCursorModifier), for: .valueChanged)
        responseLabel.text = "视角响应"
        settingsContent.addSubview(responseMode)
        responseMode.addTarget(self, action: #selector(changeResponseMode), for: .valueChanged)
        cursorLabel.text = "右摇杆移动游标"
        settingsContent.addSubview(cursorEnabled)
        cursorEnabled.addTarget(self, action: #selector(toggleCursor), for: .valueChanged)
        cursorSpeed.minimumValue = 0.2
        cursorSpeed.maximumValue = 3
        cursorSpeed.addTarget(self, action: #selector(changeCursorSpeed), for: .valueChanged)
        settingsContent.addSubview(cursorSpeed)
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 4
        var actionItems: [(String, Selector)] = [("删除此点", #selector(removeSelected))]
        if session.isDeadSpace { actionItems.append(("推荐预设", #selector(applyPreset))) }
        actionItems.append(contentsOf: [("取消", #selector(cancel)), ("保存", #selector(save))])
        for (name, selector) in actionItems {
            let button = UIButton(type: .system)
            configure(button, name, action: selector)
            actions.addArrangedSubview(button)
        }
        actions.tag = 100
        panel.addSubview(actions)
        view.bringSubviewToFront(open)
        refresh()
    }

    private func configure(_ button: UIButton, _ name: String, action: Selector) {
        button.setTitle(name, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        canvas.frame = view.bounds
        let safe = view.safeAreaInsets
        open.frame = CGRect(x: safe.left + 12, y: safe.top + 8, width: 48, height: 48)
        restoreOverlayPosition(open, position: openPosition, key: "entry")
        modeLabel.frame = CGRect(x: view.bounds.width - safe.right - 172, y: safe.top + 8,
                                 width: 160, height: 24)
        placementHint.frame = CGRect(x: open.frame.maxX + 8, y: safe.top + 8,
                                     width: max(0, view.bounds.width - safe.right - open.frame.maxX - 20), height: 40)
        let width = min(420, view.bounds.width - safe.left - safe.right - 16)
        // Keep the full panel inside the safe area, independently movable.
        let height = min(CGFloat(400), max(252, (view.bounds.height - safe.top - safe.bottom) * 0.74))
        panel.frame = CGRect(x: (view.bounds.width - width) / 2,
                             y: view.bounds.height - safe.bottom - height - 4,
                             width: width, height: height)
        restoreOverlayPosition(panel, position: panelPosition, key: "panel")
        dragHandle.frame = CGRect(x: 8, y: 2, width: width - 16, height: 28)
        titleLabel.frame = CGRect(x: 10, y: 32, width: width - 75, height: 20)
        enabled.frame = CGRect(x: width - 62, y: 30, width: 51, height: 31)
        connection.frame = CGRect(x: 10, y: 54, width: width - 80, height: 16)
        stickControls.frame = CGRect(x: 10, y: 76, width: width - 20, height: 32)
        keysLabel.frame = CGRect(x: 12, y: 113, width: width - 24, height: 16)
        let keyWidth = (width - 26) / 8
        for (column, button) in choiceButtons.enumerated() {
            button.frame = CGRect(x: 10 + CGFloat(column) * keyWidth, y: 134,
                                  width: keyWidth - 4, height: 36)
        }
        settingsScroll.frame = CGRect(x: 0, y: 179, width: width, height: max(30, height - 217))
        settingsContent.frame = CGRect(x: 0, y: 0, width: width, height: 315)
        settingsScroll.contentSize = settingsContent.bounds.size
        selectedLabel.frame = CGRect(x: 10, y: 0, width: width - 20, height: 18)
        targetMode.frame = CGRect(x: 10, y: 22, width: width - 20, height: 27)
        stickMode.frame = targetMode.frame
        radiusLabel.frame = CGRect(x: 10, y: 53, width: 90, height: 22)
        radius.frame = CGRect(x: 95, y: 49, width: width - 105, height: 30)
        deadzoneLabel.frame = CGRect(x: 10, y: 83, width: 90, height: 22)
        deadzone.frame = CGRect(x: 95, y: 79, width: width - 105, height: 30)
        cursorLabel.frame = CGRect(x: 10, y: 111, width: width - 80, height: 25)
        cursorEnabled.frame = CGRect(x: width - 62, y: 108, width: 51, height: 31)
        cursorSpeedLabel.frame = CGRect(x: 10, y: 141, width: 90, height: 22)
        cursorSpeed.frame = CGRect(x: 95, y: 137, width: width - 105, height: 30)
        invertYLabel.frame = CGRect(x: 10, y: 172, width: width - 80, height: 25)
        invertY.frame = CGRect(x: width - 62, y: 169, width: 51, height: 31)
        responseLabel.frame = CGRect(x: 10, y: 208, width: 85, height: 25)
        responseMode.frame = CGRect(x: 95, y: 205, width: width - 105, height: 28)
        cursorModifierLabel.frame = CGRect(x: 10, y: 244, width: width - 80, height: 25)
        cursorModifier.frame = CGRect(x: width - 62, y: 241, width: 51, height: 31)
        hint.frame = CGRect(x: 10, y: 276, width: width - 20, height: 35)
        panel.viewWithTag(100)?.frame = CGRect(x: 8, y: height - 32, width: width - 16, height: 28)
        updateViewport()
    }

    private var layoutKey: String { "mapping-overlay.\(session.gameID).\(session.landscape ? "landscape" : "portrait")" }

    func resetOverlayLayout() {
        openPosition = nil; panelPosition = nil
        viewIfLoaded?.setNeedsLayout()
    }

    private func availableRect(for surface: UIView) -> CGRect {
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        return CGRect(x: safe.minX, y: safe.minY,
                      width: max(0, safe.width - surface.bounds.width),
                      height: max(0, safe.height - surface.bounds.height))
    }

    private func restoreOverlayPosition(_ surface: UIView, position: CGPoint?, key: String) {
        let stored = UserDefaults.standard.array(forKey: layoutKey + "." + key) as? [Double]
        let point = position ?? (stored?.count == 2 ? CGPoint(x: stored![0], y: stored![1]) : nil)
        guard let point = point, point.x.isFinite, point.y.isFinite else { return }
        let travel = availableRect(for: surface)
        surface.frame.origin = CGPoint(x: travel.minX + min(1, max(0, point.x)) * travel.width,
                                       y: travel.minY + min(1, max(0, point.y)) * travel.height)
    }

    @objc private func dragOverlay(_ gesture: UIPanGestureRecognizer) {
        let surface = gesture.view === open ? open : panel
        if gesture.state == .began { panOrigin = surface.frame.origin; dragSurface = surface }
        guard dragSurface === surface else { return }
        let delta = gesture.translation(in: view)
        let travel = availableRect(for: surface)
        let origin = CGPoint(x: min(travel.maxX, max(travel.minX, panOrigin.x + delta.x)),
                             y: min(travel.maxY, max(travel.minY, panOrigin.y + delta.y)))
        surface.frame.origin = origin
        let unit = CGPoint(x: travel.width > 0 ? (origin.x - travel.minX) / travel.width : 0,
                           y: travel.height > 0 ? (origin.y - travel.minY) / travel.height : 0)
        if surface === open { openPosition = unit } else { panelPosition = unit }
        if gesture.state == .ended || gesture.state == .cancelled {
            UserDefaults.standard.set([Double(unit.x), Double(unit.y)],
                                      forKey: layoutKey + (surface === open ? ".entry" : ".panel"))
            dragSurface = nil
        }
    }

    func updateViewport() {
        guard isViewLoaded, let source = session.gameView else { return }
        let bounds = source.convert(source.bounds, to: canvas)
        let f = session.fractions
        let next = CGRect(x: bounds.minX + f.minX * bounds.width,
                          y: bounds.minY + f.minY * bounds.height,
                          width: f.width * bounds.width, height: f.height * bounds.height)
        if canvas.viewport != next { canvas.viewport = next; canvas.setNeedsDisplay() }
    }

    func setConnection(_ text: String) {
        if connection.text != text { connection.text = text }
    }

    func refresh() {
        guard isViewLoaded else { return }
        canvas.isUserInteractionEnabled = session.editing
        panel.isHidden = !session.editing || controlsCollapsed
        placementHint.isHidden = !session.editing || !controlsCollapsed
        placementHint.text = " \(controlNames[session.selected])：点游戏画面放置，展开后调整范围并保存"
        stickControls.selectedSegmentIndex = (15...16).contains(session.selected)
            ? session.selected - 15 : UISegmentedControl.noSegment
        open.setTitle(nil, for: .normal)
        open.setImage(UIImage(systemName: session.editing ? (controlsCollapsed ? "slider.horizontal.3" : "chevron.down") : "gamecontroller.fill"), for: .normal)
        open.accessibilityLabel = session.editing ? (controlsCollapsed ? "展开映射面板" : "收起映射面板") : "编辑手柄屏幕映射"
        titleLabel.text = "\(session.gameName) · \(session.landscape ? "横屏" : "竖屏")映射"
        enabled.isOn = session.profile.enabled
        let binding = session.selectedMapping
        let isSwipe = binding?.swipe != nil
        updateModeLabel()
        targetMode.isHidden = session.selected >= 15
        stickMode.isHidden = session.selected < 15
        stickMode.setEnabled(session.selected == 16, forSegmentAt: 2)
        stickMode.selectedSegmentIndex = session.selected == 16 && session.profile.cursor?.enabled == true
            ? 2 : (isSwipe ? 1 : 0)
        selectedLabel.text = "\(controlNames[session.selected]) \(session.selectedIndex.map { "#\($0 + 1)" } ?? "新位置")：\(isSwipe ? "持续视角滑动" : (binding?.cursorClick == true ? "点击当前游标" : (binding == nil ? "点画面添加" : "拖动标记调整")))"
        targetMode.isEnabled = session.selected < 15
        targetMode.selectedSegmentIndex = binding?.cursorClick == true ? 1 : 0
        radius.isEnabled = session.selected >= 15 && binding != nil
        radius.value = binding?.radius ?? 0.12
        radiusLabel.text = "\(isSwipe ? "滑动范围" : "摇杆范围") \(Int(radius.value * 100))%"
        deadzone.value = session.profile.deadzone
        deadzoneLabel.text = "摇杆死区 \(Int(deadzone.value * 100))%"
        cursorEnabled.isOn = session.profile.cursor?.enabled == true
        cursorSpeed.isEnabled = cursorEnabled.isOn || isSwipe
        cursorSpeed.maximumValue = isSwipe ? 3 : 2
        cursorSpeed.value = binding?.swipe?.speed ?? session.profile.cursor?.speed ?? 0.8
        cursorSpeedLabel.text = "\(isSwipe ? "视角灵敏度" : "游标速度") \(Int(cursorSpeed.value * 100))%"
        invertY.isEnabled = isSwipe
        invertY.isOn = binding?.swipe?.invertY ?? false
        cursorModifier.isEnabled = isSwipe && session.selected == 16
        cursorModifier.isOn = binding?.swipe?.cursorWithL1 ?? false
        responseMode.isEnabled = isSwipe
        responseMode.selectedSegmentIndex = binding?.swipe?.precise == false ? 0 : 1
        hint.text = session.status
        for button in choiceButtons {
            let mapped = session.profile.bindings.contains { $0.control == button.tag }
            button.backgroundColor = button.tag == session.selected ? .systemBlue
                : (mapped ? UIColor.systemGreen.withAlphaComponent(0.2) : .tertiarySystemFill)
            button.setTitleColor(button.tag == session.selected ? .white : .label, for: .normal)
        }
        canvas.setNeedsDisplay()
    }

    @objc func edit() {
        if session.editing {
            // Collapsing controls keeps the canvas active, so every screen key
            // remains reachable. The same floating button brings them back.
            controlsCollapsed.toggle()
            refresh()
        } else { controlsCollapsed = false; session.beginEditing() }
    }
    @objc func selectControl(_ sender: UIButton) {
        session.selected = sender.tag
        session.selectedBinding = nil
        session.status = "点画面添加新的 \(shortControlNames[sender.tag]) 位置；原有位置保留"
        session.placingSelected = true
        refresh()
    }
    @objc func selectStick() {
        guard (0..<2).contains(stickControls.selectedSegmentIndex) else { return }
        session.selected = 15 + stickControls.selectedSegmentIndex
        session.selectedBinding = nil
        session.placingSelected = true
        session.status = session.selected == 16
            ? "点能用手指滑动视角的区域，展开后选择视角滑动并保存"
            : "点游戏虚拟摇杆的中心，展开后调整摇杆范围并保存"
        controlsCollapsed = true
        refresh()
    }
    @objc func toggleEnabled() {
        var p = session.profile; p.enabled = enabled.isOn; session.profile = p; session.changed()
    }
    @objc func changeRadius() {
        var p = session.profile
        if let index = session.selectedIndex {
            p.bindings[index].radius = radius.value
        }
        session.profile = p; session.changed()
    }
    @objc func changeDeadzone() {
        var p = session.profile; p.deadzone = deadzone.value; session.profile = p; session.changed()
    }
    @objc func changeTarget() {
        guard session.selected < 15 else { return }
        var p = session.profile
        let cursorClick = targetMode.selectedSegmentIndex == 1
        if cursorClick {
            if let index = session.selectedIndex {
                p.bindings[index].cursorClick = true
            } else {
                guard p.bindings.count < 64 else { return }
                session.selectedBinding = p.bindings.count
                p.bindings.append(ScreenBinding(control: session.selected, x: 0.5, y: 0.5, cursorClick: true))
            }
            var cursor = p.cursor ?? ScreenCursor()
            cursor.enabled = !p.bindings.contains { $0.control == 16 && $0.swipe != nil }
            p.cursor = cursor
            p.enabled = true
        } else if let index = session.selectedIndex {
            p.bindings[index].cursorClick = nil
        }
        session.profile = p; session.changed()
    }
    @objc func toggleCursor() {
        var p = session.profile
        var cursor = p.cursor ?? ScreenCursor(); cursor.enabled = cursorEnabled.isOn; p.cursor = cursor
        session.profile = p; session.changed()
    }
    @objc func changeCursorSpeed() {
        var p = session.profile
        if let index = session.selectedIndex, p.bindings[index].swipe != nil {
            p.bindings[index].swipe?.speed = cursorSpeed.value
        } else {
            var cursor = p.cursor ?? ScreenCursor(); cursor.speed = cursorSpeed.value; p.cursor = cursor
        }
        session.profile = p; session.changed()
    }
    @objc func changeStickMode() {
        guard session.selected >= 15 else { return }
        var p = session.profile
        if stickMode.selectedSegmentIndex == 2 && session.selected == 16 {
            var cursor = p.cursor ?? ScreenCursor(); cursor.enabled = true; p.cursor = cursor
        } else {
            if session.selected == 16, var cursor = p.cursor { cursor.enabled = false; p.cursor = cursor }
            if let index = session.selectedIndex {
                p.bindings[index].swipe = stickMode.selectedSegmentIndex == 1 ? ScreenSwipe() : nil
                if stickMode.selectedSegmentIndex == 1 { p.bindings[index].radius = max(0.3, p.bindings[index].radius) }
            } else {
                guard p.bindings.count < 64 else { return }
                session.selectedBinding = p.bindings.count
                p.bindings.append(ScreenBinding(control: session.selected,
                    x: session.selected == 16 ? 0.72 : 0.2, y: 0.5, radius: 0.3,
                    swipe: stickMode.selectedSegmentIndex == 1 ? ScreenSwipe() : nil))
            }
        }
        p.enabled = true
        session.profile = p
        session.status = stickMode.selectedSegmentIndex == 1
            ? "视角滑动：中心放在可拖动视角的空白区域，推住摇杆可持续转动"
            : "点游戏画面放置；虚拟摇杆和游标是两种不同操作"
        session.changed()
    }
    @objc func changeInvertY() {
        var p = session.profile
        if let index = session.selectedIndex {
            p.bindings[index].swipe?.invertY = invertY.isOn
        }
        session.profile = p; session.changed()
    }
    @objc func changeCursorModifier() {
        var p = session.profile
        if let index = session.selectedIndex {
            p.bindings[index].swipe?.cursorWithL1 = cursorModifier.isOn
        }
        session.profile = p; session.changed()
    }
    @objc func changeResponseMode() {
        var p = session.profile
        if let index = session.selectedIndex {
            p.bindings[index].swipe?.precise = responseMode.selectedSegmentIndex == 1
        }
        session.profile = p; session.changed()
    }

    func updateModeLabel() {
        modeLabel.isHidden = session.editing || !session.profile.enabled
        let cursor = session.profile.cursor?.enabled == true || session.runtimeCursorVisible
        let camera = session.profile.bindings.contains { $0.control == 16 && $0.swipe != nil }
        modeLabel.text = cursor ? "右摇杆 · 游标" : (camera ? "右摇杆 · 视角滑动" : "右摇杆 · 虚拟摇杆")
    }
    @objc func applyPreset() {
        session.selectedBinding = nil
        session.profile = MappingSession.deadSpaceProfile()
        session.status = "左摇杆移动；右摇杆视角；RT 点击视角中心"
        session.changed()
    }
    @objc func removeSelected() {
        guard let index = session.selectedIndex else { return }
        var p = session.profile; p.bindings.remove(at: index)
        session.selectedBinding = nil
        session.profile = p; session.changed()
    }
    @objc func cancel() { session.finish(save: false) }
    @objc func save() { session.finish(save: true) }
}

private final class MappingCanvas: UIView {
    weak var session: MappingSession?
    var viewport = CGRect.zero
    var dragging = false
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let session = session, let context = UIGraphicsGetCurrentContext() else { return }
        if session.profile.enabled && (session.profile.cursor?.enabled == true || session.runtimeCursorVisible) {
            let point = CGPoint(x: viewport.minX + session.cursorPoint.x * viewport.width,
                                y: viewport.minY + session.cursorPoint.y * viewport.height)
            let ring = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(4)
            context.strokeEllipse(in: ring)
            context.setStrokeColor((session.cursorHeld ? UIColor.systemGreen : UIColor.white).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: ring)
            context.move(to: CGPoint(x: point.x - 4, y: point.y))
            context.addLine(to: CGPoint(x: point.x + 4, y: point.y))
            context.move(to: CGPoint(x: point.x, y: point.y - 4))
            context.addLine(to: CGPoint(x: point.x, y: point.y + 4))
            context.strokePath()
        }
        guard session.editing else { return }
        context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.stroke(viewport)
        for (index, binding) in session.profile.bindings.enumerated() {
            let point = CGPoint(x: viewport.minX + CGFloat(binding.x) * viewport.width,
                                y: viewport.minY + CGFloat(binding.y) * viewport.height)
            let selected = index == session.selectedIndex
            let color: UIColor = selected ? .systemYellow : .systemBlue
            if binding.control >= 15 {
                let radius = CGFloat(binding.radius) * min(viewport.width, viewport.height)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                                width: radius * 2, height: radius * 2))
            }
            let marker = CGRect(x: point.x - 22, y: point.y - 18, width: 44, height: 36)
            context.setFillColor(color.withAlphaComponent(0.8).cgColor)
            context.fillEllipse(in: marker)
            let label = "\(shortControlNames[binding.control])·\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.black
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                       withAttributes: attributes)
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let session = session, let touch = touches.first else { return }
        let point = touch.location(in: self)
        guard viewport.contains(point) else { return }
        let nearest = session.profile.bindings.indices.min {
            distance(session.profile.bindings[$0], point) < distance(session.profile.bindings[$1], point)
        }
        if !session.placingSelected, let index = nearest,
           distance(session.profile.bindings[index], point) < 27 {
            session.selected = session.profile.bindings[index].control
            session.selectedBinding = index
        } else if !session.placingSelected {
            session.selectedBinding = nil
        }
        session.placingSelected = false
        dragging = true
        session.place(at: point, viewport: viewport)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let touch = touches.first else { return }
        session?.place(at: touch.location(in: self), viewport: viewport)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = false }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = false }
    private func distance(_ binding: ScreenBinding, _ point: CGPoint) -> CGFloat {
        hypot(viewport.minX + CGFloat(binding.x) * viewport.width - point.x,
              viewport.minY + CGFloat(binding.y) * viewport.height - point.y)
    }
}
