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
