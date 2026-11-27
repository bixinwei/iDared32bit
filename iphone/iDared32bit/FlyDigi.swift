/*
 * Load the FlyDigi keymapping SDK at launch (only for FlyDigi gamepads), and
 * read the controller-system toggles so FlyDigi and the built-in MFi mapping
 * can be switched independently.
 *
 * Toggle file (optional): Documents/controller_mapping.json
 *   { "flydigi": true, "mfi": true }
 * Omit the file (or a key) to leave that system enabled.
 */
import Foundation
import Darwin

private struct ControllerToggles {
    var flydigi = true
    var mfi = true

    static func load() -> ControllerToggles {
        var toggles = ControllerToggles()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("controller_mapping.json")
        if let data = try? Data(contentsOf: url),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            toggles.flydigi = json["flydigi"] as? Bool ?? true
            toggles.mfi = json["mfi"] as? Bool ?? true
        }
        return toggles
    }
}

@_cdecl("idared_load_flydigi")
public func idaredLoadFlyDigi() {
    let toggles = ControllerToggles.load()
    UserDefaults.standard.set(toggles.flydigi, forKey: "FlyDigiEnabled")
    UserDefaults.standard.set(toggles.mfi, forKey: "MFiMappingEnabled")

    guard toggles.flydigi else {
        return
    }
    let root = Bundle.main.bundleURL
    for name in ["flydigi", "libcklib"] {
        let path = root.appendingPathComponent(name + ".dylib").path
        if dlopen(path, RTLD_NOW | RTLD_GLOBAL) == nil {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            print("iDared: failed to load FlyDigi \(name): \(reason)")
        }
    }
}