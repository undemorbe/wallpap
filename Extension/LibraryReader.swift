import Foundation

/// Read-only view of the Wallpap library (written by the app) from inside the
/// sandboxed extension. Access is granted by the
/// `temporary-exception.files.home-relative-path.read-only` entitlement.
struct LibraryReader {
    struct Item: Decodable {
        var id: UUID
        var name: String
        var kind: String
        var fileName: String
        var thumbName: String
    }
    struct Snapshot: Decodable {
        var items: [Item]
        var activeID: UUID?
    }

    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var supportDir: URL { realHome.appending(path: "Library/Application Support/Wallpap", directoryHint: .isDirectory) }
    static var itemsDir: URL { supportDir.appending(path: "Items", directoryHint: .isDirectory) }

    static func load() -> Snapshot {
        let url = supportDir.appending(path: "library.json")
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            ExtLog.write("library.json unreadable at \(url.path)")
            return Snapshot(items: [], activeID: nil)
        }
        return snap
    }

    static var videos: [Item] { load().items.filter { $0.kind == "video" } }

    static func fileURL(_ item: Item) -> URL { itemsDir.appending(path: item.fileName) }
    static func thumbURL(_ item: Item) -> URL { itemsDir.appending(path: item.thumbName) }

    /// Choice configuration ↔ item id.
    static func configuration(for item: Item) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: ["itemID": item.id.uuidString],
                                             format: .binary, options: 0)) ?? Data()
    }

    static func item(forConfiguration data: Data?) -> Item? {
        let snap = load()
        let videos = snap.items.filter { $0.kind == "video" }
        if let data,
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let idString = dict["itemID"] as? String,
           let found = videos.first(where: { $0.id.uuidString == idString }) {
            return found
        }
        return videos.first(where: { $0.id == snap.activeID }) ?? videos.first
    }
}

enum ExtLog {
    private static let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wallpap-extension.log")
    private static let queue = DispatchQueue(label: "log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.sync {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
