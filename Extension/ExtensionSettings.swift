import AVFoundation
import Foundation
import IOKit.ps

/// Playback settings shared with the app through
/// `~/Library/Application Support/Wallpap/settings.json` (re-read when the file changes).
struct ExtensionSettings: Decodable {
    var animateOnDesktop = true
    var animateOnLockScreen = true
    var pauseWhenHidden = true
    var pauseOnBattery = false
    var pauseInLowPowerMode = true
    var playbackSpeed = 1.0
    var scaling = "fill"
    /// 0 = system default, -1 = until unlocked, otherwise minutes.
    var lockScreenAwakeMinutes = 5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExtensionSettings()
        animateOnDesktop = try c.decodeIfPresent(Bool.self, forKey: .animateOnDesktop) ?? d.animateOnDesktop
        animateOnLockScreen = try c.decodeIfPresent(Bool.self, forKey: .animateOnLockScreen) ?? d.animateOnLockScreen
        pauseWhenHidden = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHidden) ?? d.pauseWhenHidden
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? d.pauseOnBattery
        pauseInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? d.pauseInLowPowerMode
        playbackSpeed = min(2, max(0.25, try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? d.playbackSpeed))
        scaling = try c.decodeIfPresent(String.self, forKey: .scaling) ?? d.scaling
        lockScreenAwakeMinutes = try c.decodeIfPresent(Int.self, forKey: .lockScreenAwakeMinutes) ?? d.lockScreenAwakeMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case animateOnDesktop, animateOnLockScreen, pauseWhenHidden, pauseOnBattery, pauseInLowPowerMode, playbackSpeed, scaling,
             lockScreenAwakeMinutes
    }

    var videoGravity: AVLayerVideoGravity { scaling == "fit" ? .resizeAspect : .resizeAspectFill }

    func shouldAnimate(presentationMode: String, isActive: Bool) -> Bool {
        if pauseWhenHidden && !isActive { return false }
        if pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if pauseOnBattery && Self.isOnBattery { return false }
        switch presentationMode {
        case "locked", "idle": return animateOnLockScreen
        default: return animateOnDesktop
        }
    }

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    // MARK: Loading

    private static var url: URL { LibraryReader.supportDir.appending(path: "settings.json") }
    private static var cached = ExtensionSettings()
    private static var cachedStamp: Date?

    /// Current settings; cheap (re-decodes only when the file's modification date changes).
    static var current: ExtensionSettings {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if stamp != cachedStamp {
            cachedStamp = stamp
            if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(ExtensionSettings.self, from: data) {
                cached = s
            } else {
                cached = ExtensionSettings()
            }
        }
        return cached
    }
}
