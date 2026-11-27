/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Host app lifecycle bridge: pause the guest when the app leaves the
// foreground, so the CPU, audio and timer keep quiet in the background.
import UIKit

@_silgen_name("idared_start_flydigi_window_keeper")
private func idaredStartFlyDigiWindowKeeper()

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
        },
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            HostActivity.inactive = false
            idaredStartFlyDigiWindowKeeper()
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