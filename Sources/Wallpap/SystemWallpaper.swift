import Foundation

/// Integration with the native macOS 26 wallpaper subsystem.
///
/// Videos are installed as the local file of a built-in Aerial asset ("slot"),
/// so `WallpaperAgent` plays them itself: nothing of ours has to run.
/// Images use the system image provider. In both cases the choice is written
/// to the wallpaper store (`Index.plist`) and the agent is restarted.
enum SystemWallpaper {
    /// Built-in Aerial whose local video file is replaced ("Mac Purple").
    static let slotAssetID = "D8C8FC8B-9D11-4803-944F-DF284B35FE58"
    static let slotDisplayName = "Mac Purple"

    static let aerialsProvider = "com.apple.wallpaper.choice.aerials"
    static let imageProvider = "com.apple.wallpaper.choice.image"

    static var base: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.wallpaper", directoryHint: .isDirectory)
    }
    static var storeURL: URL { base.appending(path: "Store/Index.plist") }
    static var videosDir: URL { base.appending(path: "aerials/videos", directoryHint: .isDirectory) }
    static var thumbsDir: URL { base.appending(path: "aerials/thumbnails", directoryHint: .isDirectory) }
    static var slotVideoURL: URL { videosDir.appending(path: "\(slotAssetID).mov") }
    static var slotThumbURL: URL { thumbsDir.appending(path: "\(slotAssetID).png") }

    enum Failure: LocalizedError {
        case storeMissing
        case storeUnreadable

        var errorDescription: String? {
            switch self {
            case .storeMissing:
                return "Не найдено хранилище обоев macOS (\(SystemWallpaper.storeURL.path)). Откройте один раз «Системные настройки → Обои»."
            case .storeUnreadable:
                return "Не удалось прочитать Index.plist хранилища обоев."
            }
        }
    }

    // MARK: Public API

    /// Provider of the embedded wallpaper extension (equals its bundle identifier).
    static let extensionProvider = "local.dolbobob.wallpap.wallpaper"

    /// Desktop: our wallpaper extension (live video, hosted by WallpaperAgent).
    /// Screen saver: the same video through the built-in Aerial slot.
    static func applyVideo(itemID: UUID, movie: URL, thumbnail: URL?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        backupSlotThumbnailIfNeeded()

        try replaceFile(at: slotVideoURL, with: movie)
        if let thumbnail { try? replaceFile(at: slotThumbURL, with: thumbnail) }

        try setChoice(provider: extensionProvider,
                      configuration: ["itemID": itemID.uuidString],
                      targets: ["Desktop"])
        try setChoice(provider: aerialsProvider,
                      configuration: ["assetID": slotAssetID],
                      targets: ["Idle"])
        restartAgent()
    }

    static func applyImage(_ image: URL) throws {
        try setChoice(provider: imageProvider,
                      configuration: ["type": "imageFile", "url": ["relative": image.absoluteString]],
                      targets: ["Desktop"])
        restartAgent()
    }

    /// Removes our video from the slot and restores the original thumbnail.
    static func resetSlot() {
        let fm = FileManager.default
        try? fm.removeItem(at: slotVideoURL)
        let backup = Library.supportDir.appending(path: "slot-thumbnail-original.png")
        if fm.fileExists(atPath: backup.path) { try? replaceFile(at: slotThumbURL, with: backup) }
        restartAgent()
    }

    static var slotIsInstalled: Bool { FileManager.default.fileExists(atPath: slotVideoURL.path) }

    static func restartAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Store editing

    private static func setChoice(provider: String, configuration: [String: Any], targets: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { throw Failure.storeMissing }
        let data = try Data(contentsOf: storeURL)
        guard let root = try PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainersAndLeaves], format: nil) as? NSMutableDictionary
        else { throw Failure.storeUnreadable }

        let conf = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
        let opts = try PropertyListSerialization.data(fromPropertyList: ["values": [String: Any]()], format: .binary, options: 0)
        func makeContent() -> NSMutableDictionary {
            [
                "Choices": [["Configuration": conf, "Files": [Any](), "Provider": provider] as NSDictionary],
                "EncodedOptionValues": opts,
                "Shuffle": "$null",
            ]
        }

        var replaced = 0
        func walk(_ node: Any) {
            if let dict = node as? NSMutableDictionary {
                for case let key as String in dict.allKeys {
                    let value = dict[key]
                    if targets.contains(key), let entry = value as? NSMutableDictionary, entry["Content"] != nil {
                        entry["Content"] = makeContent()
                        entry["LastSet"] = Date()
                        replaced += 1
                    } else if let value {
                        walk(value)
                    }
                }
            } else if let array = node as? NSMutableArray {
                array.forEach(walk)
            }
        }
        walk(root)

        // Fresh store without per-display entries: set the global default.
        if replaced == 0 || root["AllSpacesAndDisplays"] == nil {
            let all = (root["AllSpacesAndDisplays"] as? NSMutableDictionary) ?? NSMutableDictionary()
            for t in targets where all[t] == nil {
                all[t] = NSMutableDictionary(dictionary: ["Content": makeContent(), "LastSet": Date(), "LastUse": Date()])
            }
            if all["Type"] == nil { all["Type"] = "linked" }
            root["AllSpacesAndDisplays"] = all
        }

        let out = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try out.write(to: storeURL, options: .atomic)
    }

    // MARK: Helpers

    private static func backupSlotThumbnailIfNeeded() {
        let backup = Library.supportDir.appending(path: "slot-thumbnail-original.png")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: slotThumbURL.path) else { return }
        try? fm.copyItem(at: slotThumbURL, to: backup)
    }

    /// Copies `source` over `target` atomically (temp file in the same directory, then swap).
    static func replaceFile(at target: URL, with source: URL) throws {
        let fm = FileManager.default
        let tmp = target.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        try fm.copyItem(at: source, to: tmp)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: target)
        }
    }
}
