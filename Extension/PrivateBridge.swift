import Foundation
import IOSurface
import ObjectiveC

/// Bridge to the wallpaper XPC types that live in the system's private
/// WallpaperExtensionKit framework.
///
/// The framework is loaded at runtime only so that its NSSecureCoding wrapper
/// classes (`WallpaperIDXPC`, `WallpaperCreationRequestXPC`, …) exist in this
/// process: NSXPC then decodes the agent's messages into the real classes.
/// Each wrapper stores its payload as a property-list object under a key that
/// is the payload's type name, so outgoing objects are built from plain
/// dictionaries and incoming ones are read with `Mirror`.
enum PrivateBridge {
    static let extensionProtocolName = "WallpaperExtensionKit.WallpaperExtensionXPCProtocol"
    static let proxyProtocolName = "WallpaperExtensionKit.WallpaperExtensionProxyXPCProtocol"

    static let isLoaded: Bool = {
        var ok = true
        for fw in ["WallpaperTypes", "WallpaperFoundation", "WallpaperExtensionKit"] {
            let path = "/System/Library/PrivateFrameworks/\(fw).framework/Versions/A/\(fw)"
            if dlopen(path, RTLD_NOW) == nil {
                ok = false
                ExtLog.write("dlopen failed: \(path) \(String(cString: dlerror()))")
            }
        }
        return ok
    }()

    static var extensionProtocol: Protocol? { _ = isLoaded; return objc_getProtocol(extensionProtocolName) }
    static var proxyProtocol: Protocol? { _ = isLoaded; return objc_getProtocol(proxyProtocolName) }

    // MARK: Building outgoing objects

    /// Instantiates wrapper class `className` via `initWithCoder:` with `value` stored under `key`.
    static func make(_ className: String, key: String, value: Any) -> NSObject? {
        _ = isLoaded
        guard let cls = objc_getClass(className) as? NSObject.Type else {
            ExtLog.write("missing class \(className)")
            return nil
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(value, forKey: key)
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { return nil }
        unarchiver.requiresSecureCoding = false
        guard let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let result = allocated.perform(NSSelectorFromString("initWithCoder:"), with: unarchiver)?
                  .takeUnretainedValue() as? NSObject
        else {
            ExtLog.write("make \(className) failed: \(unarchiver.error.map { "\($0)" } ?? "?")")
            return nil
        }
        return result
    }

    static func remoteContext(_ contextID: UInt32) -> NSObject? {
        make("WallpaperRemoteContextXPC", key: "UInt32", value: NSNumber(value: contextID))
    }

    static func settingsViewModels(_ dict: [String: Any]) -> NSObject? {
        make("WallpaperSettingsViewModelsXPC", key: "WallpaperSettingsViewModels", value: dict)
    }

    static func debugSuccess() -> NSObject? {
        make("WallpaperDebugResponseXPC", key: "WallpaperDebugResponse", value: ["success": [String: Any]()])
    }

    /// `WallpaperSnapshotXPC` wraps `WallpaperSnapshot { surface: IOSurfaceRef }` and is
    /// encoded as an XPC object, so it is built by writing the ivar directly.
    static func snapshot(_ surface: IOSurface) -> NSObject? {
        _ = isLoaded
        guard let cls = objc_getClass("WallpaperSnapshotXPC") as? NSObject.Type,
              let ivar = class_getInstanceVariable(cls, "rawValue"),
              let obj = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        let slot = Unmanaged.passUnretained(obj).toOpaque() + ivar_getOffset(ivar)
        slot.storeBytes(of: Unmanaged.passRetained(surface).toOpaque(), as: UnsafeMutableRawPointer.self)
        return obj
    }

    // MARK: Reading incoming objects

    /// Payload of a wrapper object (unwraps `box: XPCBox<T>` / `rawValue: T`).
    static func payload(_ object: Any?) -> Any? {
        guard let object else { return nil }
        guard let first = Mirror(reflecting: object).children.first else { return nil }
        if first.label == "box" {
            return Mirror(reflecting: first.value).children.first(where: { $0.label == "rawValue" })?.value
        }
        return first.value
    }

    /// Follows a path of stored-property names through nested values, unwrapping optionals.
    static func value(_ root: Any?, _ path: String...) -> Any? {
        var current = root.flatMap(unwrapOptional)
        for name in path {
            guard let c = current,
                  let child = Mirror(reflecting: c).children.first(where: { $0.label == name })
            else { return nil }
            current = unwrapOptional(child.value)
        }
        return current
    }

    static func unwrapOptional(_ any: Any) -> Any? {
        let m = Mirror(reflecting: any)
        guard m.displayStyle == .optional else { return any }
        return m.children.first.map { unwrapOptional($0.value) } ?? nil
    }

    /// Case name of an enum value (e.g. "default", "locked", "active").
    static func caseName(_ any: Any?) -> String? {
        guard let any else { return nil }
        let m = Mirror(reflecting: any)
        if m.displayStyle == .enum, let label = m.children.first?.label { return label }
        return "\(any)".components(separatedBy: ".").last
    }

    static func wallpaperID(_ object: NSObject) -> String {
        if let uuid = value(payload(object), "id") as? UUID { return uuid.uuidString }
        return "\(payload(object) ?? object)"
    }
}
