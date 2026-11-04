import Foundation

enum Providers {
    static func make(_ source: SourceID) -> any WallpaperProvider {
        switch source {
        case .wallhaven: WallhavenProvider()
        case .pexels: PexelsProvider()
        case .pixabay: PixabayProvider()
        case .aerials: AerialsProvider()
        case .bing: BingProvider()
        case .unsplash: UnsplashProvider()
        case .openverse: OpenverseProvider()
        case .commons: CommonsProvider()
        case .nasa: NASAProvider()
        case .wallpaperscraft: WallpapersCraftProvider()
        }
    }
}

// MARK: - Wallhaven  (https://wallhaven.cc/help/api)

struct WallhavenProvider: WallpaperProvider {
    let source = SourceID.wallhaven

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Thumbs: Decodable { let large: URL; let original: URL }
            let id: String
            let url: URL
            let views: Int
            let favorites: Int
            let category: String
            let dimension_x: Int
            let dimension_y: Int
            let file_size: Int
            let file_type: String
            let created_at: String
            let colors: [String]
            let path: URL
            let thumbs: Thumbs
        }
        struct Meta: Decodable { let current_page: Int; let last_page: Int }
        let data: [Item]
        let meta: Meta
    }

    /// Categories bitmask general/anime/people, set in settings.
    static var categories: String { UserDefaults.standard.string(forKey: "wallhaven.categories") ?? "111" }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .video else { return .empty }
        let sorting: String = switch q.sort {
        case .popular: "views"
        case .favorites: "favorites"
        case .top: "toplist"
        case .latest: "date_added"
        case .random: "random"
        }
        let r = q.resolution.size
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let url = HTTP.url("https://wallhaven.cc/api/v1/search", [
            "q": text.isEmpty ? nil : text,
            "categories": Self.categories,
            "purity": "100",
            "sorting": sorting,
            "order": "desc",
            "topRange": q.sort == .top ? q.period.rawValue : nil,
            "atleast": r.w > 0 ? (q.orientation == .portrait ? "\(r.h)x\(r.w)" : "\(r.w)x\(r.h)") : nil,
            "ratios": q.orientation == .any ? nil : q.orientation.rawValue,
            "page": String(page),
        ])
        let resp = try await HTTP.json(Response.self, source: source, url: url)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let items = resp.data.map { i in
            RemoteWallpaper(
                source: source, remoteID: i.id, kind: .image,
                title: "\(i.category.capitalized) · \(i.id)",
                pageURL: i.url, thumbURL: i.thumbs.large, downloadURL: i.path,
                fileExtension: i.path.pathExtension.isEmpty ? "jpg" : i.path.pathExtension,
                width: i.dimension_x, height: i.dimension_y,
                views: i.views, favorites: i.favorites, fileSize: i.file_size,
                createdAt: fmt.date(from: i.created_at), tags: [i.category], colors: i.colors)
        }
        return ProviderPage(items: items, hasMore: resp.meta.current_page < resp.meta.last_page)
    }
}

// MARK: - Pexels  (https://www.pexels.com/api/documentation/)

struct PexelsProvider: WallpaperProvider {
    let source = SourceID.pexels

    private struct Photos: Decodable {
        struct Photo: Decodable {
            struct Src: Decodable { let original: URL; let large: URL; let large2x: URL }
            let id: Int
            let width: Int
            let height: Int
            let url: URL
            let photographer: String
            let alt: String?
            let src: Src
        }
        let photos: [Photo]
        let next_page: String?
    }

    private struct Videos: Decodable {
        struct Video: Decodable {
            struct User: Decodable { let name: String }
            struct File: Decodable {
                let quality: String?
                let file_type: String?
                let width: Int?
                let height: Int?
                let link: URL
            }
            let id: Int
            let width: Int
            let height: Int
            let url: URL
            let image: URL
            let duration: Double
            let user: User
            let video_files: [File]
        }
        let videos: [Video]
        let next_page: String?
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard let key = source.apiKey else { throw RemoteError.missingKey(source) }
        switch q.kind {
        case .image: return try await photos(q, page: page, key: key)
        case .video: return try await videos(q, page: page, key: key)
        case .all:
            async let p = photos(q, page: page, key: key)
            async let v = videos(q, page: page, key: key)
            let (a, b) = try await (p, v)
            return ProviderPage(items: interleave(b.items, a.items), hasMore: a.hasMore || b.hasMore)
        }
    }

    private func photos(_ q: CatalogQuery, page: Int, key: String) async throws -> ProviderPage {
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let url = text.isEmpty
            ? HTTP.url("https://api.pexels.com/v1/curated", ["page": String(page), "per_page": "40"])
            : HTTP.url("https://api.pexels.com/v1/search", [
                "query": text, "page": String(page), "per_page": "40",
                "orientation": q.orientation == .any ? nil : q.orientation.rawValue,
                "size": q.resolution.rawValue >= 2160 ? "large" : nil,
            ])
        let resp = try await HTTP.json(Photos.self, source: source, url: url, headers: ["Authorization": key])
        let items = resp.photos.map { p in
            RemoteWallpaper(
                source: source, remoteID: "p\(p.id)", kind: .image,
                title: (p.alt?.isEmpty == false ? p.alt! : "Фото \(p.id)"),
                author: p.photographer, pageURL: p.url, thumbURL: p.src.large,
                downloadURL: p.src.original,
                fileExtension: p.src.original.pathExtension.isEmpty ? "jpg" : p.src.original.pathExtension,
                width: p.width, height: p.height)
        }
        return ProviderPage(items: items, hasMore: resp.next_page != nil)
    }

    private func videos(_ q: CatalogQuery, page: Int, key: String) async throws -> ProviderPage {
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let r = q.resolution.size
        let url = text.isEmpty
            ? HTTP.url("https://api.pexels.com/videos/popular", [
                "page": String(page), "per_page": "40",
                "min_width": r.w > 0 ? String(r.w) : nil,
                "max_duration": q.maxDuration > 0 ? String(q.maxDuration) : nil,
            ])
            : HTTP.url("https://api.pexels.com/videos/search", [
                "query": text, "page": String(page), "per_page": "40",
                "orientation": q.orientation == .any ? nil : q.orientation.rawValue,
                "size": r.w >= 3840 ? "large" : (r.w >= 1920 ? "medium" : nil),
            ])
        let resp = try await HTTP.json(Videos.self, source: source, url: url, headers: ["Authorization": key])
        let items: [RemoteWallpaper] = resp.videos.compactMap { v in
            let mp4 = v.video_files.filter { ($0.file_type ?? "video/mp4") == "video/mp4" && $0.width != nil }
            // Best file up to 4K (bigger files rarely add anything on a desktop).
            guard let best = mp4.filter({ ($0.width ?? 0) <= 4096 }).max(by: { ($0.width ?? 0) < ($1.width ?? 0) })
                ?? mp4.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) else { return nil }
            let preview = mp4.filter { ($0.width ?? 0) >= 480 }.min(by: { ($0.width ?? 0) < ($1.width ?? 0) })
            return RemoteWallpaper(
                source: source, remoteID: "v\(v.id)", kind: .video,
                title: Self.title(from: v.url) ?? "Видео \(v.id)",
                author: v.user.name, pageURL: v.url, thumbURL: v.image,
                previewVideoURL: preview?.link, downloadURL: best.link, fileExtension: "mp4",
                width: best.width ?? v.width, height: best.height ?? v.height, duration: v.duration)
        }
        return ProviderPage(items: items, hasMore: resp.next_page != nil)
    }

    /// Pexels page URLs look like /video/aerial-view-of-a-forest-12345/.
    static func title(from url: URL) -> String? {
        var slug = url.lastPathComponent
        if let r = slug.range(of: #"-\d+$"#, options: .regularExpression) { slug.removeSubrange(r) }
        guard !slug.isEmpty, slug != "video" else { return nil }
        let s = slug.replacingOccurrences(of: "-", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

// MARK: - Pixabay  (https://pixabay.com/api/docs/#api_search_videos)

struct PixabayProvider: WallpaperProvider {
    let source = SourceID.pixabay

    private struct Response: Decodable {
        struct Hit: Decodable {
            /// Pixabay sends empty strings and zero sizes for missing renditions.
            struct File: Decodable {
                let url: String
                let width: Int
                let height: Int
                let size: Int?
                let thumbnail: String?
                var link: URL? { url.isEmpty || width == 0 ? nil : URL(string: url) }
                var thumb: URL? { thumbnail.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
            }
            struct Files: Decodable { let large: File?; let medium: File?; let small: File?; let tiny: File? }
            let id: Int
            let pageURL: URL
            let tags: String
            let duration: Double
            let views: Int
            let downloads: Int
            let likes: Int
            let user: String
            let picture_id: String?
            let videos: Files
        }
        let totalHits: Int
        let hits: [Hit]
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .image else { return .empty }
        guard let key = source.apiKey else { throw RemoteError.missingKey(source) }
        let r = q.resolution.size
        let perPage = 40
        let url = HTTP.url("https://pixabay.com/api/videos/", [
            "key": key,
            "q": q.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(q.text.prefix(100)),
            "order": q.sort == .latest ? "latest" : "popular",
            "min_width": r.w > 0 ? String(q.orientation == .portrait ? r.h : r.w) : nil,
            "min_height": r.h > 0 ? String(q.orientation == .portrait ? r.w : r.h) : nil,
            "safesearch": "true",
            "per_page": String(perPage),
            "page": String(page),
        ])
        let resp = try await HTTP.json(Response.self, source: source, url: url)
        let items: [RemoteWallpaper] = resp.hits.compactMap { h in
            let files = [h.videos.large, h.videos.medium, h.videos.small].compactMap { $0 }
            guard let best = files.first(where: { $0.link != nil }), let bestURL = best.link else { return nil }
            let thumb = h.videos.medium?.thumb ?? h.videos.large?.thumb ?? h.videos.small?.thumb
                ?? h.picture_id.flatMap { URL(string: "https://i.vimeocdn.com/video/\($0)_640x360.jpg") }
            guard let thumb else { return nil }
            let tags = h.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let title = tags.prefix(3).joined(separator: ", ")
            return RemoteWallpaper(
                source: source, remoteID: String(h.id), kind: .video,
                title: title.isEmpty ? "Видео \(h.id)" : title.prefix(1).uppercased() + title.dropFirst(),
                author: h.user, pageURL: h.pageURL, thumbURL: thumb,
                previewVideoURL: h.videos.tiny?.link ?? h.videos.small?.link,
                downloadURL: bestURL, fileExtension: "mp4",
                width: best.width, height: best.height, duration: h.duration,
                views: h.views, favorites: h.likes, downloads: h.downloads, fileSize: best.size, tags: tags)
        }
        return ProviderPage(items: items, hasMore: page * perPage < min(resp.totalHits, 500))
    }
}

// MARK: - Apple Aerials (manifest shipped with macOS)

struct AerialsProvider: WallpaperProvider {
    let source = SourceID.aerials

    private struct Manifest: Decodable {
        struct Asset: Decodable {
            let id: String
            let accessibilityLabel: String?
            let localizedNameKey: String?
            let previewImage: URL?
            let categories: [String]?
            let url: URL?
            enum CodingKeys: String, CodingKey {
                case id, accessibilityLabel, localizedNameKey, previewImage, categories
                case url = "url-4K-SDR-240FPS"
            }
        }
        struct Category: Decodable { let id: String; let localizedNameKey: String }
        let assets: [Asset]
        let categories: [Category]
    }

    static var manifestDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.wallpaper/aerials/manifest", directoryHint: .isDirectory)
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .image, page == 1, q.orientation != .portrait else { return .empty }
        let file = Self.manifestDir.appending(path: "entries.json")
        guard let data = try? Data(contentsOf: file) else {
            throw RemoteError.unavailable("Каталог Aerials не найден. Откройте «Системные настройки → Обои» один раз, чтобы macOS его загрузила.")
        }
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        let strings = Bundle(url: Self.manifestDir.appending(path: "TVIdleScreenStrings.bundle"))
        func loc(_ key: String?, _ fallback: String) -> String {
            guard let key, let strings else { return fallback }
            let s = strings.localizedString(forKey: key, value: nil, table: "Localizable.nocache")
            return s == key ? fallback : s
        }
        let catNames = Dictionary(m.categories.map { ($0.id, loc($0.localizedNameKey, "")) }, uniquingKeysWith: { a, _ in a })
        let items: [RemoteWallpaper] = m.assets.compactMap { a in
            guard let url = a.url, let thumb = a.previewImage, a.id != SystemWallpaper.slotAssetID else { return nil }
            let tags = (a.categories ?? []).compactMap { catNames[$0] }.filter { !$0.isEmpty }
            return RemoteWallpaper(
                source: source, remoteID: a.id, kind: .video,
                title: loc(a.localizedNameKey, a.accessibilityLabel ?? "Aerial"),
                author: "Apple", thumbURL: thumb, downloadURL: url, fileExtension: "mov",
                width: 3840, height: 2160, tags: tags)
        }
        return ProviderPage(items: items, hasMore: false)
    }
}

// MARK: - Bing image of the day

struct BingProvider: WallpaperProvider {
    let source = SourceID.bing

    private struct Response: Decodable {
        struct Image: Decodable {
            let startdate: String
            let urlbase: String
            let copyright: String
            let copyrightlink: String?
            let hsh: String
        }
        let images: [Image]
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .video, page <= 2 else { return .empty }
        let market = "en-US" // stable captions; unknown markets fall back unpredictably
        let url = HTTP.url("https://www.bing.com/HPImageArchive.aspx", [
            "format": "js", "idx": String((page - 1) * 8), "n": "8", "mkt": market,
        ])
        let resp = try await HTTP.json(Response.self, source: source, url: url)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let portrait = q.orientation == .portrait
        let items: [RemoteWallpaper] = resp.images.compactMap { i in
            let suffix = portrait ? "_1080x1920.jpg" : "_UHD.jpg"
            guard let full = URL(string: "https://www.bing.com\(i.urlbase)\(suffix)"),
                  let thumb = URL(string: "https://www.bing.com\(i.urlbase)\(portrait ? "_1080x1920.jpg" : "_800x480.jpg")")
            else { return nil }
            var title = i.copyright
            var author: String?
            if let r = title.range(of: " (©") {
                author = String(title[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                title = String(title[..<r.lowerBound])
            }
            return RemoteWallpaper(
                source: source, remoteID: i.hsh, kind: .image, title: title, author: author,
                pageURL: i.copyrightlink.flatMap(URL.init(string:)), thumbURL: thumb, downloadURL: full,
                fileExtension: "jpg", width: portrait ? 1080 : 3840, height: portrait ? 1920 : 2160,
                createdAt: fmt.date(from: i.startdate))
        }
        return ProviderPage(items: items, hasMore: page < 2)
    }
}

// MARK: - Unsplash  (https://unsplash.com/documentation)

struct UnsplashProvider: WallpaperProvider {
    let source = SourceID.unsplash

    private struct Photo: Decodable {
        struct URLs: Decodable { let raw: URL; let regular: URL }
        struct Links: Decodable { let html: URL; let download_location: URL? }
        struct User: Decodable { let name: String }
        let id: String
        let width: Int
        let height: Int
        let color: String?
        let likes: Int?
        let created_at: String?
        let description: String?
        let alt_description: String?
        let urls: URLs
        let links: Links
        let user: User
    }
    private struct Search: Decodable { let total_pages: Int; let results: [Photo] }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .video else { return .empty }
        guard source.apiKey != nil else { throw RemoteError.missingKey(source) }
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let orientation: String? = switch q.orientation { case .landscape: "landscape"; case .portrait: "portrait"; case .any: nil }
        let photos: [Photo]
        let hasMore: Bool
        if text.isEmpty {
            // Without a query Unsplash has no orientation filter, so browse a wallpaper search instead.
            let url = HTTP.url("https://api.unsplash.com/search/photos", [
                "query": "wallpaper", "page": String(page), "per_page": "30",
                "orientation": orientation, "order_by": q.sort == .latest ? "latest" : "relevant",
            ])
            let r = try await HTTP.json(Search.self, source: source, url: url, headers: source.authHeaders)
            photos = r.results; hasMore = page < r.total_pages
        } else {
            let url = HTTP.url("https://api.unsplash.com/search/photos", [
                "query": text, "page": String(page), "per_page": "30",
                "orientation": orientation, "order_by": q.sort == .latest ? "latest" : "relevant",
            ])
            let r = try await HTTP.json(Search.self, source: source, url: url, headers: source.authHeaders)
            photos = r.results; hasMore = page < r.total_pages
        }
        let iso = ISO8601DateFormatter()
        let items = photos.map { p in
            let title = (p.description ?? p.alt_description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Raw URL + imgix params: up to 5K JPEG, never upscaled.
            var full = URLComponents(url: p.urls.raw, resolvingAgainstBaseURL: false)!
            full.queryItems = (full.queryItems ?? []) + [URLQueryItem(name: "w", value: String(min(p.width, 5120))),
                                                         URLQueryItem(name: "fm", value: "jpg"), URLQueryItem(name: "q", value: "88")]
            let scale = p.width > 5120 ? 5120 / Double(p.width) : 1
            return RemoteWallpaper(
                source: source, remoteID: p.id, kind: .image,
                title: title.isEmpty ? "Фото \(p.user.name)" : String(title.prefix(80)).capitalizedFirst,
                author: p.user.name, pageURL: p.links.html, thumbURL: p.urls.regular,
                downloadURL: full.url ?? p.urls.raw, fileExtension: "jpg",
                width: Int(Double(p.width) * scale), height: Int(Double(p.height) * scale),
                favorites: p.likes, createdAt: p.created_at.flatMap(iso.date(from:)),
                colors: p.color.map { [$0] } ?? [], pingURL: p.links.download_location)
        }
        return ProviderPage(items: items, hasMore: hasMore)
    }
}

// MARK: - Openverse  (https://api.openverse.org/v1/)

struct OpenverseProvider: WallpaperProvider {
    let source = SourceID.openverse

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Tag: Decodable { let name: String }
            let id: String
            let title: String?
            let url: URL
            let thumbnail: URL?
            let foreign_landing_url: URL?
            let creator: String?
            let license: String
            let license_version: String?
            let provider: String?
            let width: Int?
            let height: Int?
            let filesize: Int?
            let filetype: String?
            let tags: [Tag]?
        }
        let page_count: Int
        let results: [Item]
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .video else { return .empty }
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let ratio: String? = switch q.orientation { case .landscape: "wide"; case .portrait: "tall"; case .any: nil }
        let url = HTTP.url("https://api.openverse.org/v1/images/", [
            "q": text.isEmpty ? "landscape wallpaper" : text,
            "page": String(page), "page_size": "20", // anonymous limit
            "size": "large",
            "aspect_ratio": ratio,
            "extension": "jpg",
        ])
        let resp = try await HTTP.json(Response.self, source: source, url: url)
        let items: [RemoteWallpaper] = resp.results.map { i in
            let lic = "CC \(i.license.uppercased())\(i.license_version.map { " \($0)" } ?? "")"
            let title = (i.title ?? "").trimmingCharacters(in: .whitespaces)
            return RemoteWallpaper(
                source: source, remoteID: i.id, kind: .image,
                title: title.isEmpty ? "Фото \(i.id.prefix(6))" : title.capitalizedFirst,
                author: i.creator, pageURL: i.foreign_landing_url, thumbURL: i.thumbnail ?? i.url,
                downloadURL: i.url, fileExtension: i.filetype ?? "jpg",
                width: i.width ?? 0, height: i.height ?? 0, fileSize: i.filesize,
                tags: (i.tags ?? []).prefix(8).map(\.name) + [i.provider].compactMap { $0 }, license: lic)
        }
        return ProviderPage(items: items, hasMore: page < min(resp.page_count, 20))
    }
}

// MARK: - Wikimedia Commons featured pictures

struct CommonsProvider: WallpaperProvider {
    let source = SourceID.commons

    private struct Response: Decodable {
        struct Page: Decodable {
            struct Info: Decodable {
                struct Meta: Decodable { let value: String }
                let size: Int?
                let width: Int
                let height: Int
                let thumburl: URL?
                let url: URL
                let descriptionurl: URL?
                let extmetadata: [String: Meta]?
            }
            let index: Int?
            let title: String
            let imageinfo: [Info]?
        }
        struct Query: Decodable { let pages: [String: Page] }
        struct Continue: Decodable { let gsroffset: Int? }
        let query: Query?
        let `continue`: Continue?
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .video else { return .empty }
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let perPage = 40
        let order: String? = switch q.sort { case .latest: "create_timestamp_desc"; case .random: "random"; default: nil }
        let url = HTTP.url("https://commons.wikimedia.org/w/api.php", [
            "action": "query", "format": "json", "generator": "search", "gsrnamespace": "6",
            "gsrsearch": "\(text) incategory:Featured_pictures_on_Wikimedia_Commons filemime:image/jpeg".trimmingCharacters(in: .whitespaces),
            "gsrlimit": String(perPage), "gsroffset": String((page - 1) * perPage),
            "gsrsort": order,
            "prop": "imageinfo", "iiprop": "url|size|extmetadata", "iiurlwidth": "800",
            "iiextmetadatafilter": "Artist|LicenseShortName|DateTimeOriginal|ObjectName",
        ])
        let resp = try await HTTP.json(Response.self, source: source, url: url)
        let pages = (resp.query?.pages.values).map(Array.init) ?? []
        let items: [RemoteWallpaper] = pages.sorted { ($0.index ?? 0) < ($1.index ?? 0) }.compactMap { p in
            guard let info = p.imageinfo?.first else { return nil }
            var name = p.title.replacingOccurrences(of: "File:", with: "")
            if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
            let meta = info.extmetadata ?? [:]
            return RemoteWallpaper(
                source: source, remoteID: String(p.title.hashValue.magnitude),
                kind: .image, title: name.replacingOccurrences(of: "_", with: " "),
                author: meta["Artist"].map { Self.plain($0.value) }, pageURL: info.descriptionurl,
                thumbURL: info.thumburl ?? info.url, downloadURL: info.url, fileExtension: "jpg",
                width: info.width, height: info.height, fileSize: info.size,
                license: meta["LicenseShortName"].map { Self.plain($0.value) })
        }
        return ProviderPage(items: items, hasMore: resp.continue?.gsroffset != nil)
    }

    /// extmetadata values are HTML snippets.
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - NASA Image and Video Library  (https://images.nasa.gov/docs/images.nasa.gov_api_docs.pdf)

struct NASAProvider: WallpaperProvider {
    let source = SourceID.nasa

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Data: Decodable {
                let nasa_id: String
                let title: String
                let media_type: String
                let date_created: String?
                let center: String?
                let keywords: [String]?
            }
            struct Link: Decodable { let href: URL; let rel: String?; let width: Int?; let height: Int?; let size: Int? }
            let data: [Data]
            let links: [Link]?
        }
        struct Collection: Decodable {
            struct Meta: Decodable { let total_hits: Int }
            let items: [Item]
            let metadata: Meta?
        }
        let collection: Collection
    }

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        let media: String = switch q.kind { case .video: "video"; case .image: "image"; case .all: "image,video" }
        let text = q.text.trimmingCharacters(in: .whitespaces)
        let perPage = 40
        let url = HTTP.url("https://images-api.nasa.gov/search", [
            "q": text.isEmpty ? "earth from space" : text,
            "media_type": media, "page": String(page), "page_size": String(perPage),
        ])
        let resp = try await HTTP.json(Response.self, source: source, url: url)
        let iso = ISO8601DateFormatter()
        let items: [RemoteWallpaper] = resp.collection.items.compactMap { item in
            guard let d = item.data.first, let thumb = item.links?.first(where: { $0.rel == "preview" })?.href
                ?? item.links?.first?.href else { return nil }
            let base = "https://images-assets.nasa.gov/\(d.media_type)/\(d.nasa_id)/\(d.nasa_id)"
            func asset(_ suffix: String) -> URL? {
                URL(string: (base + suffix).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
            }
            let date = d.date_created.flatMap { iso.date(from: $0) }
            if d.media_type == "video" {
                guard let file = asset("~orig.mp4") else { return nil }
                return RemoteWallpaper(
                    source: source, remoteID: d.nasa_id, kind: .video, title: d.title,
                    author: d.center.map { "NASA \($0)" } ?? "NASA", pageURL: URL(string: "https://images.nasa.gov/details/\(d.nasa_id)".addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
                    thumbURL: thumb, previewVideoURL: asset("~preview.mp4"), downloadURL: file, fileExtension: "mp4",
                    width: 0, height: 0, createdAt: date, tags: d.keywords ?? [])
            }
            let orig = item.links?.first(where: { $0.rel == "canonical" })
            guard let file = orig?.href ?? asset("~orig.jpg") else { return nil }
            return RemoteWallpaper(
                source: source, remoteID: d.nasa_id, kind: .image, title: d.title,
                author: d.center.map { "NASA \($0)" } ?? "NASA",
                pageURL: URL(string: "https://images.nasa.gov/details/\(d.nasa_id)".addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
                thumbURL: thumb, downloadURL: file, fileExtension: file.pathExtension.isEmpty ? "jpg" : file.pathExtension,
                width: orig?.width ?? 0, height: orig?.height ?? 0, fileSize: orig?.size, createdAt: date, tags: d.keywords ?? [])
        }
        let total = resp.collection.metadata?.total_hits ?? 0
        return ProviderPage(items: items, hasMore: page * perPage < min(total, 10_000))
    }
}

// MARK: - WallpapersCraft (HTML pages; robots.txt allows the catalogue, asks for 1 s between requests)

struct WallpapersCraftProvider: WallpaperProvider {
    let source = SourceID.wallpaperscraft
    private static let throttle = Throttle(interval: 1.1)

    func fetch(_ q: CatalogQuery, page: Int) async throws -> ProviderPage {
        guard q.kind != .video else { return .empty }
        let size: String
        if q.orientation == .portrait { size = "1080x1920" }
        else { size = q.resolution == .fiveK ? "5120x2880" : "3840x2160" }
        let section: String = switch q.sort {
        case .popular, .top: "all/downloads"
        case .favorites: "all/ratings"
        case .latest, .random: "all"
        }
        let path = "https://wallpaperscraft.ru/\(section)/\(size)" + (page > 1 ? "/page\(page)" : "")
        await Self.throttle.wait()
        let (data, resp) = try await HTTP.session.data(from: URL(string: path)!)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw RemoteError.http(source, http.statusCode) }
        let html = String(decoding: data, as: UTF8.self)

        let item = try! NSRegularExpression(pattern:
            #"href="/download/([a-z0-9_]+)/(\d+)x(\d+)".*?gui-icon_download"></span>&nbsp;(\d+).*?<span class="wallpapers__info">([^<]*)</span>"#,
            options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let items: [RemoteWallpaper] = item.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let slug = ns.substring(with: m.range(at: 1))
            let w = Int(ns.substring(with: m.range(at: 2))) ?? 0, h = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let downloads = Int(ns.substring(with: m.range(at: 4)))
            let tags = ns.substring(with: m.range(at: 5)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let img = "https://images.wallpaperscraft.ru/image/single/\(slug)"
            guard let full = URL(string: "\(img)_\(w)x\(h).jpg"),
                  let thumb = URL(string: "\(img)_\(w > h ? "1280x720" : "300x168").jpg") else { return nil }
            let id = slug.split(separator: "_").last.map(String.init) ?? slug
            return RemoteWallpaper(
                source: source, remoteID: id, kind: .image,
                title: tags.joined(separator: ", ").capitalizedFirst,
                pageURL: URL(string: "https://wallpaperscraft.ru/download/\(slug)/\(w)x\(h)"),
                thumbURL: thumb, downloadURL: full, fileExtension: "jpg",
                width: w, height: h, downloads: downloads, tags: tags)
        }
        let pages = try! NSRegularExpression(pattern: #"/page(\d+)""#)
            .matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        return ProviderPage(items: items, hasMore: page < (pages.max() ?? 1))
    }
}

/// Spaces out requests to one host.
actor Throttle {
    private let interval: TimeInterval
    private var next = Date.distantPast
    init(interval: TimeInterval) { self.interval = interval }
    func wait() async {
        let now = Date.now
        let start = max(now, next)
        next = start.addingTimeInterval(interval)
        if start > now { try? await Task.sleep(for: .seconds(start.timeIntervalSince(now))) }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Alternates two arrays: a1, b1, a2, b2, …
func interleave<T>(_ a: [T], _ b: [T]) -> [T] {
    var out: [T] = []
    out.reserveCapacity(a.count + b.count)
    for i in 0..<max(a.count, b.count) {
        if i < a.count { out.append(a[i]) }
        if i < b.count { out.append(b[i]) }
    }
    return out
}
