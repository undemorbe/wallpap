import AVFoundation
import Foundation
import ImageIO
import Observation

struct WallpaperItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case video, image }

    var id: UUID
    var name: String
    var kind: Kind
    /// Media file inside the library folder (HEVC .mov for videos, original file for images).
    var fileName: String
    /// Preview PNG inside the library folder.
    var thumbName: String
    var addedAt: Date
    // Optional so libraries saved by older versions still decode.
    var isFavorite: Bool?
    var source: SourceID?
    var remoteID: String?
    var pageURL: URL?
    var author: String?
    var width: Int?
    var height: Int?
    var duration: Double?

    var favorite: Bool { isFavorite ?? false }
    var resolutionLabel: String? {
        guard let width, let height else { return nil }
        return RemoteWallpaper.resolutionLabel(width: width, height: height)
    }

    var fileURL: URL { Library.itemsDir.appending(path: fileName) }
    var thumbURL: URL { Library.itemsDir.appending(path: thumbName) }
}

@MainActor
@Observable
final class Library {
    nonisolated static var supportDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Wallpap", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var itemsDir: URL {
        let dir = supportDir.appending(path: "Items", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexURL: URL { supportDir.appending(path: "library.json") }

    struct Snapshot: Codable {
        var items: [WallpaperItem]
        var activeID: UUID?
    }

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var progress: Double?
        var remoteID: String?
    }

    private(set) var items: [WallpaperItem] = []
    private(set) var activeID: UUID?
    var jobs: [Job] = []
    var errorMessage: String?

    init() { load() }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        items = snap.items.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        activeID = snap.activeID
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Snapshot(items: items, activeID: activeID)) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        for url in urls { _ = await importFile(url) }
    }

    @discardableResult
    func importFile(_ url: URL, name customName: String? = nil, from remote: RemoteWallpaper? = nil) async -> WallpaperItem? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let name = customName ?? url.deletingPathExtension().lastPathComponent
        let job = Job(title: "Импорт «\(name)»", progress: nil)
        jobs.append(job)
        defer { jobs.removeAll { $0.id == job.id } }

        do {
            let item: WallpaperItem
            if Media.isVideo(url) {
                let fileName = "\(id.uuidString).mov"
                let dest = Self.itemsDir.appending(path: fileName)
                let jobID = job.id
                try await Media.transcodeVideo(from: url, to: dest) { p in
                    Task { @MainActor [weak self] in
                        guard let self, let i = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                        self.jobs[i].progress = p
                    }
                }
                let thumbName = "\(id.uuidString)-thumb.png"
                let frame = try await Media.videoFrame(dest)
                try Media.writePNG(frame, to: Self.itemsDir.appending(path: thumbName))
                item = WallpaperItem(id: id, name: name, kind: .video, fileName: fileName,
                                     thumbName: thumbName, addedAt: .now)
            } else if Media.isImage(url) {
                let fileName = "\(id.uuidString).\(url.pathExtension.lowercased())"
                try FileManager.default.copyItem(at: url, to: Self.itemsDir.appending(path: fileName))
                let thumbName = "\(id.uuidString)-thumb.png"
                let thumb = try Media.imageThumbnail(url)
                try Media.writePNG(thumb, to: Self.itemsDir.appending(path: thumbName))
                item = WallpaperItem(id: id, name: name, kind: .image, fileName: fileName,
                                     thumbName: thumbName, addedAt: .now)
            } else {
                errorMessage = "«\(url.lastPathComponent)» — неподдерживаемый формат."
                return nil
            }
            var stored = item
            if let remote {
                stored.source = remote.source
                stored.remoteID = remote.id
                stored.pageURL = remote.pageURL
                stored.author = remote.author
                stored.width = remote.width
                stored.height = remote.height
                stored.duration = remote.duration
            } else {
                await stored.fillDimensions()
            }
            items.insert(stored, at: 0)
            save()
            return stored
        } catch {
            errorMessage = "Не удалось импортировать «\(name)»: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Online catalog

    /// Library entry already downloaded from this remote wallpaper.
    func item(for remote: RemoteWallpaper) -> WallpaperItem? {
        items.first { $0.remoteID == remote.id }
    }

    func isDownloading(_ remote: RemoteWallpaper) -> Bool {
        jobs.contains { $0.remoteID == remote.id }
    }

    /// Downloads a remote wallpaper into the library (or returns the existing copy).
    @discardableResult
    func download(_ remote: RemoteWallpaper) async -> WallpaperItem? {
        if let existing = item(for: remote) { return existing }
        guard !isDownloading(remote) else { return nil }
        var job = Job(title: "Загрузка «\(remote.title)»", progress: 0)
        job.remoteID = remote.id
        jobs.append(job)
        let jobID = job.id
        do {
            let file = try await Downloader.download(remote.downloadURL,
                                                     fileName: "\(remote.title).\(remote.fileExtension)") { p in
                Task { @MainActor [weak self] in
                    guard let self, let i = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                    self.jobs[i].progress = p
                }
            }
            jobs.removeAll { $0.id == jobID }
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            if let ping = remote.pingURL {
                var req = URLRequest(url: ping)
                for (k, v) in remote.source.authHeaders { req.setValue(v, forHTTPHeaderField: k) }
                _ = try? await HTTP.session.data(for: req)
            }
            return await importFile(file, name: remote.title, from: remote)
        } catch {
            jobs.removeAll { $0.id == jobID }
            errorMessage = "Не удалось скачать «\(remote.title)»: \(error.localizedDescription)"
            return nil
        }
    }

    func downloadAndApply(_ remote: RemoteWallpaper) async {
        if let item = await download(remote) { await apply(item) }
    }

    // MARK: Actions

    func toggleFavorite(_ item: WallpaperItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isFavorite = !items[i].favorite
        save()
    }

    func apply(_ item: WallpaperItem) async {
        let job = Job(title: "Установка «\(item.name)»", progress: nil)
        jobs.append(job)
        defer { jobs.removeAll { $0.id == job.id } }
        do {
            switch item.kind {
            case .video:
                // System Settings tile thumbnail (214×130 @2x).
                let tile = Self.supportDir.appending(path: "slot-tile.png")
                if let img = try? Media.imageThumbnail(item.thumbURL) {
                    try? Media.writePNG(img, to: tile, fill: CGSize(width: 428, height: 260))
                }
                let movie = item.fileURL
                let itemID = item.id
                activeID = item.id
                save() // the extension reads library.json to resolve the item
                try await Task.detached(priority: .userInitiated) {
                    try SystemWallpaper.applyVideo(itemID: itemID, movie: movie, thumbnail: tile)
                }.value
            case .image:
                let file = item.fileURL
                try await Task.detached(priority: .userInitiated) {
                    try SystemWallpaper.applyImage(file)
                }.value
            }
            activeID = item.id
            save()
        } catch {
            errorMessage = "Не удалось установить фон: \(error.localizedDescription)"
        }
    }

    func rename(_ item: WallpaperItem, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        items[i].name = name
        save()
    }

    func delete(_ item: WallpaperItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        try? FileManager.default.removeItem(at: item.thumbURL)
        items.removeAll { $0.id == item.id }
        if activeID == item.id { activeID = nil }
        save()
    }

    func resetSystemSlot() {
        SystemWallpaper.resetSlot()
        if let id = activeID, items.first(where: { $0.id == id })?.kind == .video { activeID = nil }
        save()
    }
}

extension WallpaperItem {
    /// Reads pixel size (and duration for videos) from the stored file.
    mutating func fillDimensions() async {
        switch kind {
        case .image:
            if let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                width = props[kCGImagePropertyPixelWidth] as? Int
                height = props[kCGImagePropertyPixelHeight] as? Int
            }
        case .video:
            let asset = AVURLAsset(url: fileURL)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let t = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(t)
                width = Int(abs(r.width)); height = Int(abs(r.height))
            }
            if let d = try? await asset.load(.duration) { duration = d.seconds }
        }
    }
}
