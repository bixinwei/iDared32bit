/*
 * Load the FlyDigi keymapping SDK at launch.
 *
 * The FlyDigi dylibs and resource bundle are copied into the app bundle by the
 * build workflow. `dlopen` runs each dylib's constructors, which start the
 * FlyDigi floating mapping UI and its Bluetooth gamepad connection.
 */
import Foundation
import Darwin

@_cdecl("idared_load_flydigi")
public func idaredLoadFlyDigi() {
    let root = Bundle.main.bundleURL
    for name in ["flydigi", "libcklib"] {
        let path = root.appendingPathComponent(name + ".dylib").path
        if dlopen(path, RTLD_NOW | RTLD_GLOBAL) == nil {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            print("iDared: failed to load FlyDigi \(name): \(reason)")
        }
    }
}