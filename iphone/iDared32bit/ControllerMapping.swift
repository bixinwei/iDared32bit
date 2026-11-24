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
    var version = 1
    var portrait = ScreenProfile()
    var landscape = ScreenProfile()
}

private let controlNames = [
    "A / ×", "B / ○", "X / □", "Y / △", "L1 / LB", "R1 / RB",
    "L2 / LT", "R2 / RT", "L3", "R3", "Start / Options",
    "方向键 ←", "方向键 ↑", "方向键 →", "方向键 ↓",
    "左摇杆", "右摇杆", "十字键摇杆"
]
private let shortControlNames = [
    "A", "B", "X", "Y", "L1", "R1", "L2", "R2", "L3", "R3", "Start",
    "←", "↑", "→", "↓", "左摇杆", "右摇杆", "十字键"
]

private enum ScreenMapper {
    // Called only on SDL's main thread, except stop() which hops to that thread.
    nonisolated(unsafe) static var session: MappingSession?
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
           loaded.version == 1 {
            loaded.portrait = Self.validated(loaded.portrait)
            loaded.landscape = Self.validated(loaded.landscape)
            configuration = loaded
        } else {
            configuration = ScreenConfiguration()
            if gameID.lowercased().hasPrefix("com.ea.deadspace") {
                // Starting layout, not a claim about every level's controls.
                // The cursor is what makes arbitrary contextual targets usable.
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
        var seen = Set<Int>()
        result.bindings = input.bindings.filter {
            (0..<18).contains($0.control) && $0.x.isFinite && $0.y.isFinite
                && (0...1).contains($0.x) && (0...1).contains($0.y)
                && $0.radius.isFinite && (0.025...0.3).contains($0.radius)
                && seen.insert($0.control).inserted
        }
        return result
    }

    static func deadSpaceProfile() -> ScreenProfile {
        ScreenProfile(enabled: true, deadzone: 0.15, bindings: [
            ScreenBinding(control: 15, x: 0.18, y: 0.75, radius: 0.14),
            ScreenBinding(control: 6, x: 0.7, y: 0.5, cursorClick: true)
        ], cursor: ScreenCursor())
    }

    func changed() {
        // Bound to exactly representable Float integers in the C snapshot.
        revision = revision % 16_000_000 + 1
        waitingForNeutral = true
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
        status = "选手柄键，再点游戏画面；可拖动已有标记"
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
        if let index = p.bindings.firstIndex(where: { $0.control == selected }) {
            p.bindings[index].x = x
            p.bindings[index].y = y
            p.bindings[index].cursorClick = nil
        } else {
            p.bindings.append(ScreenBinding(control: selected, x: x, y: y))
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
            if neutral { waitingForNeutral = false }
            return []
        }
        guard profile.enabled, !editing, UIApplication.shared.applicationState == .active,
              let canvas = controller?.canvas, canvas.viewport.width > 0,
              canvas.viewport.height > 0 else {
            waitingForNeutral = true
            return []
        }
        let viewport = canvas.viewport
        let shorter = Float(min(viewport.width, viewport.height))
        if let cursor = profile.cursor, cursor.enabled {
            let (x, y) = sticks[1]
            let magnitude = hypotf(x, y)
            if magnitude > profile.deadzone {
                let speed = (min(1, magnitude) - profile.deadzone) / (1 - profile.deadzone)
                    * cursor.speed * shorter * dt
                cursorPoint.x = min(1, max(0, cursorPoint.x + CGFloat(x / magnitude * speed / Float(viewport.width))))
                cursorPoint.y = min(1, max(0, cursorPoint.y + CGFloat(y / magnitude * speed / Float(viewport.height))))
                canvas.setNeedsDisplay()
            }
        }
        var result: [[Float]] = []
        for binding in profile.bindings {
            if binding.control < 15 {
                if buttons[binding.control] >= 0.25 {
                    if binding.cursorClick == true {
                        guard profile.cursor?.enabled == true else { continue }
                        let x = Float(cursorPoint.x), y = Float(cursorPoint.y)
                        result.append([Float(binding.control), x, y, x, y])
                        cursorHeld = true
                        canvas.setNeedsDisplay()
                    } else {
                        result.append([Float(binding.control), binding.x, binding.y, binding.x, binding.y])
                    }
                }
            } else {
                if binding.control == 16 && profile.cursor?.enabled == true { continue }
                let (x, y) = sticks[binding.control - 15]
                let magnitude = hypotf(x, y)
                guard magnitude > profile.deadzone else { continue }
                let distance = (min(1, magnitude) - profile.deadzone) / (1 - profile.deadzone)
                let radius = binding.radius * shorter
                let px = binding.x + x / magnitude * distance * radius / Float(viewport.width)
                let py = binding.y + y / magnitude * distance * radius / Float(viewport.height)
                result.append([Float(binding.control), min(1, max(0, px)), min(1, max(0, py)),
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
    let title = UILabel()
    let connection = UILabel()
    let hint = UILabel()
    let selectedLabel = UILabel()
    let enabled = UISwitch()
    let radius = UISlider()
    let radiusLabel = UILabel()
    let deadzone = UISlider()
    let deadzoneLabel = UILabel()
    let targetMode = UISegmentedControl(items: ["固定位置", "游标点击"])
    let cursorEnabled = UISwitch()
    let cursorLabel = UILabel()
    let cursorSpeed = UISlider()
    let cursorSpeedLabel = UILabel()
    let scroll = UIScrollView()
    let choices = UIStackView()
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
        canvas.session = session
        view.addSubview(canvas)
        configure(open, "手柄", action: #selector(edit))
        open.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        open.setTitleColor(.white, for: .normal)
        open.layer.cornerRadius = 18
        open.accessibilityLabel = "编辑手柄屏幕映射"
        view.addSubview(open)
        panel.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        panel.layer.cornerRadius = 16
        view.addSubview(panel)
        for label in [title, connection, hint, selectedLabel, radiusLabel, deadzoneLabel, cursorLabel, cursorSpeedLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .label
            panel.addSubview(label)
        }
        title.font = .boldSystemFont(ofSize: 14)
        hint.numberOfLines = 2
        hint.font = .systemFont(ofSize: 11)
        panel.addSubview(enabled)
        enabled.addTarget(self, action: #selector(toggleEnabled), for: .valueChanged)
        choices.axis = .horizontal
        choices.spacing = 6
        scroll.addSubview(choices)
        panel.addSubview(scroll)
        for (index, name) in controlNames.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            configure(button, name, action: #selector(selectControl(_:)))
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
            button.layer.cornerRadius = 8
            choices.addArrangedSubview(button)
            choiceButtons.append(button)
        }
        radius.minimumValue = 0.025
        radius.maximumValue = 0.3
        radius.addTarget(self, action: #selector(changeRadius), for: .valueChanged)
        panel.addSubview(radius)
        deadzone.minimumValue = 0.05
        deadzone.maximumValue = 0.5
        deadzone.addTarget(self, action: #selector(changeDeadzone), for: .valueChanged)
        panel.addSubview(deadzone)
        panel.addSubview(targetMode)
        targetMode.addTarget(self, action: #selector(changeTarget), for: .valueChanged)
        cursorLabel.text = "右摇杆移动游标"
        panel.addSubview(cursorEnabled)
        cursorEnabled.addTarget(self, action: #selector(toggleCursor), for: .valueChanged)
        cursorSpeed.minimumValue = 0.2
        cursorSpeed.maximumValue = 2
        cursorSpeed.addTarget(self, action: #selector(changeCursorSpeed), for: .valueChanged)
        panel.addSubview(cursorSpeed)
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 4
        var actionItems: [(String, Selector)] = [("删除此键", #selector(removeSelected))]
        if session.isDeadSpace { actionItems.append(("推荐预设", #selector(applyPreset))) }
        actionItems.append(contentsOf: [("取消", #selector(cancel)), ("保存", #selector(save))])
        for (name, selector) in actionItems {
            let button = UIButton(type: .system)
            configure(button, name, action: selector)
            actions.addArrangedSubview(button)
        }
        actions.tag = 100
        panel.addSubview(actions)
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
        open.frame = CGRect(x: safe.left + 12, y: safe.top + 8, width: 66, height: 36)
        let width = min(500, view.bounds.width - safe.left - safe.right - 16)
        // Dock the editor along the bottom; hide it to position a key underneath.
        let height: CGFloat = 308
        panel.frame = CGRect(x: (view.bounds.width - width) / 2,
                             y: view.bounds.height - safe.bottom - height - 4,
                             width: width, height: height)
        title.frame = CGRect(x: 10, y: 7, width: width - 75, height: 20)
        enabled.frame = CGRect(x: width - 62, y: 5, width: 51, height: 31)
        connection.frame = CGRect(x: 10, y: 28, width: width - 80, height: 16)
        scroll.frame = CGRect(x: 8, y: 47, width: width - 16, height: 33)
        let choiceSize = choices.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        choices.frame = CGRect(origin: .zero, size: CGSize(width: choiceSize.width, height: 33))
        scroll.contentSize = choices.bounds.size
        selectedLabel.frame = CGRect(x: 10, y: 83, width: width - 20, height: 18)
        targetMode.frame = CGRect(x: 10, y: 103, width: width - 20, height: 27)
        radiusLabel.frame = CGRect(x: 10, y: 134, width: 90, height: 22)
        radius.frame = CGRect(x: 95, y: 130, width: width - 105, height: 30)
        deadzoneLabel.frame = CGRect(x: 10, y: 164, width: 90, height: 22)
        deadzone.frame = CGRect(x: 95, y: 160, width: width - 105, height: 30)
        cursorLabel.frame = CGRect(x: 10, y: 192, width: width - 80, height: 25)
        cursorEnabled.frame = CGRect(x: width - 62, y: 189, width: 51, height: 31)
        cursorSpeedLabel.frame = CGRect(x: 10, y: 222, width: 90, height: 22)
        cursorSpeed.frame = CGRect(x: 95, y: 218, width: width - 105, height: 30)
        hint.frame = CGRect(x: 10, y: 249, width: width - 20, height: 28)
        panel.viewWithTag(100)?.frame = CGRect(x: 8, y: 277, width: width - 16, height: 28)
        updateViewport()
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
        open.setTitle(session.editing ? (controlsCollapsed ? "展开" : "收起") : "手柄", for: .normal)
        title.text = "\(session.gameName) · \(session.landscape ? "横屏" : "竖屏")映射"
        enabled.isOn = session.profile.enabled
        let binding = session.profile.bindings.first { $0.control == session.selected }
        selectedLabel.text = "\(controlNames[session.selected])：\(binding?.cursorClick == true ? "点击当前游标" : (binding == nil ? "点画面添加" : "拖动标记调整"))"
        targetMode.isEnabled = session.selected < 15
        targetMode.selectedSegmentIndex = binding?.cursorClick == true ? 1 : 0
        radius.isEnabled = session.selected >= 15 && binding != nil
        radius.value = binding?.radius ?? 0.12
        radiusLabel.text = "摇杆范围 \(Int(radius.value * 100))%"
        deadzone.value = session.profile.deadzone
        deadzoneLabel.text = "摇杆死区 \(Int(deadzone.value * 100))%"
        cursorEnabled.isOn = session.profile.cursor?.enabled == true
        cursorSpeed.isEnabled = cursorEnabled.isOn
        cursorSpeed.value = session.profile.cursor?.speed ?? 0.8
        cursorSpeedLabel.text = "游标速度 \(Int(cursorSpeed.value * 100))%"
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
    @objc func selectControl(_ sender: UIButton) { session.selected = sender.tag; refresh() }
    @objc func toggleEnabled() {
        var p = session.profile; p.enabled = enabled.isOn; session.profile = p; session.changed()
    }
    @objc func changeRadius() {
        var p = session.profile
        if let index = p.bindings.firstIndex(where: { $0.control == session.selected }) {
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
            if let index = p.bindings.firstIndex(where: { $0.control == session.selected }) {
                p.bindings[index].cursorClick = true
            } else {
                p.bindings.append(ScreenBinding(control: session.selected, x: 0.5, y: 0.5, cursorClick: true))
            }
            var cursor = p.cursor ?? ScreenCursor(); cursor.enabled = true; p.cursor = cursor
            p.enabled = true
        } else if let index = p.bindings.firstIndex(where: { $0.control == session.selected }) {
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
        var cursor = p.cursor ?? ScreenCursor(); cursor.speed = cursorSpeed.value; p.cursor = cursor
        session.profile = p; session.changed()
    }
    @objc func applyPreset() {
        session.profile = MappingSession.deadSpaceProfile()
        session.status = "左摇杆移动；右摇杆游标；R2/RT 点击或按住拖动"
        session.changed()
    }
    @objc func removeSelected() {
        var p = session.profile; p.bindings.removeAll { $0.control == session.selected }
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
        if session.profile.enabled && session.profile.cursor?.enabled == true {
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
        for binding in session.profile.bindings where binding.cursorClick != true {
            let point = CGPoint(x: viewport.minX + CGFloat(binding.x) * viewport.width,
                                y: viewport.minY + CGFloat(binding.y) * viewport.height)
            let selected = binding.control == session.selected
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
            let label = shortControlNames[binding.control] as NSString
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
        let nearest = session.profile.bindings.filter { $0.cursorClick != true }.min {
            distance($0, point) < distance($1, point)
        }
        if let nearest = nearest, distance(nearest, point) < 27 {
            session.selected = nearest.control
        }
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
