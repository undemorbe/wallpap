import Foundation
import Observation

/// Playback settings for the live wallpaper. Stored in
/// `~/Library/Application Support/Wallpap/settings.json`; the wallpaper extension
/// re-reads the file within ~2 seconds, so changes apply without restarting anything.
struct PlaybackSettings: Codable, Equatable {
    enum Scaling: String, Codable, CaseIterable, Identifiable {
        case fill, fit
        var id: String { rawValue }
        var title: String { self == .fill ? "Заполнить экран" : "Вписать целиком" }
    }

    var animateOnDesktop = true
    var animateOnLockScreen = true
    var pauseWhenHidden = true
    var pauseOnBattery = false
    var pauseInLowPowerMode = true
    var playbackSpeed = 1.0
    var scaling: Scaling = .fill
    /// How long the lock screen stays lit while the video plays: 0 = system default, -1 = until unlocked.
    var lockScreenAwakeMinutes = 5

    static let lockScreenAwakeChoices: [(minutes: Int, title: String)] = [
        (0, "Как в системе"), (1, "1 минуту"), (5, "5 минут"), (15, "15 минут"), (30, "30 минут"),
        (-1, "Пока не разблокирую"),
    ]

    init() {}

    /// Tolerates missing keys, so adding a setting never resets the user's other settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlaybackSettings()
        animateOnDesktop = try c.decodeIfPresent(Bool.self, forKey: .animateOnDesktop) ?? d.animateOnDesktop
        animateOnLockScreen = try c.decodeIfPresent(Bool.self, forKey: .animateOnLockScreen) ?? d.animateOnLockScreen
        pauseWhenHidden = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHidden) ?? d.pauseWhenHidden
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? d.pauseOnBattery
        pauseInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? d.pauseInLowPowerMode
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? d.playbackSpeed
        scaling = (try? c.decodeIfPresent(Scaling.self, forKey: .scaling)) ?? d.scaling
        lockScreenAwakeMinutes = try c.decodeIfPresent(Int.self, forKey: .lockScreenAwakeMinutes) ?? d.lockScreenAwakeMinutes
    }
}

@MainActor
@Observable
final class SettingsStore {
    var settings: PlaybackSettings {
        didSet { if settings != oldValue { save() } }
    }

    private static var url: URL { Library.supportDir.appending(path: "settings.json") }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let decoded = try? JSONDecoder().decode(PlaybackSettings.self, from: data) {
            settings = decoded
        } else {
            settings = PlaybackSettings()
            save()
        }
    }

    func reset() { settings = PlaybackSettings() }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) { try? data.write(to: Self.url, options: .atomic) }
    }
}
