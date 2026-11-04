import Foundation

/// Online services the catalog can browse.
enum SourceID: String, CaseIterable, Codable, Identifiable, Sendable {
    case wallhaven, wallpaperscraft, unsplash, pexels, pixabay, openverse, commons, nasa, aerials, bing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wallhaven: "Wallhaven"
        case .pexels: "Pexels"
        case .pixabay: "Pixabay"
        case .aerials: "Apple Aerials"
        case .bing: "Bing: фото дня"
        case .unsplash: "Unsplash"
        case .openverse: "Openverse"
        case .commons: "Wikimedia Commons"
        case .nasa: "NASA"
        case .wallpaperscraft: "WallpapersCraft"
        }
    }

    var symbol: String {
        switch self {
        case .wallhaven: "mountain.2"
        case .pexels: "camera.aperture"
        case .pixabay: "film.stack"
        case .aerials: "airplane"
        case .bing: "sun.max"
        case .unsplash: "camera"
        case .openverse: "globe.americas"
        case .commons: "building.columns"
        case .nasa: "sparkles"
        case .wallpaperscraft: "paintpalette"
        }
    }

    var website: URL {
        switch self {
        case .wallhaven: URL(string: "https://wallhaven.cc")!
        case .pexels: URL(string: "https://www.pexels.com")!
        case .pixabay: URL(string: "https://pixabay.com")!
        case .aerials: URL(string: "https://support.apple.com/guide/mac-help/mchl3a8ef8d1/mac")!
        case .bing: URL(string: "https://www.bing.com")!
        case .unsplash: URL(string: "https://unsplash.com")!
        case .openverse: URL(string: "https://openverse.org")!
        case .commons: URL(string: "https://commons.wikimedia.org")!
        case .nasa: URL(string: "https://images.nasa.gov")!
        case .wallpaperscraft: URL(string: "https://wallpaperscraft.ru")!
        }
    }

    /// Short description shown in settings and empty states.
    var summary: String {
        switch self {
        case .wallhaven: "Фото-обои в высоком разрешении: просмотры, избранное, топ за период. Ключ не нужен."
        case .pexels: "Бесплатные фото и видео. Нужен бесплатный ключ API."
        case .pixabay: "Бесплатные видео до 4K с просмотрами, загрузками и лайками. Нужен бесплатный ключ API."
        case .aerials: "Видео с аэросъёмкой от Apple в 4K. Каталог берётся из macOS, ключ не нужен."
        case .bing: "Фото дня Bing за последние две недели в 4K. Ключ не нужен."
        case .unsplash: "Профессиональные фото с лайками. Нужен бесплатный ключ (Access Key)."
        case .openverse: "Поиск по 800+ млн открытых фото со всего интернета (Flickr, музеи, Commons). Ключ не нужен."
        case .commons: "Избранные снимки Wikimedia Commons — лучшие фото по отбору сообщества. Ключ не нужен."
        case .nasa: "Фото и видео NASA: космос, Земля с орбиты, туманности. Ключ не нужен."
        case .wallpaperscraft: "Большой каталог обоев 4K и 5K с числом загрузок и рейтингом. Читается со страниц сайта, ключ не нужен."
        }
    }

    var kinds: Set<WallpaperItem.Kind> {
        switch self {
        case .wallhaven, .bing, .unsplash, .openverse, .commons, .wallpaperscraft: [.image]
        case .pexels, .nasa: [.image, .video]
        case .pixabay, .aerials: [.video]
        }
    }

    var needsKey: Bool { self == .pexels || self == .pixabay || self == .unsplash }

    var keyURL: URL? {
        switch self {
        case .pexels: URL(string: "https://www.pexels.com/api/new/")
        case .pixabay: URL(string: "https://pixabay.com/api/docs/")
        case .unsplash: URL(string: "https://unsplash.com/oauth/applications")
        default: nil
        }
    }

    /// Whether items carry view counters (used by the "min views" filter).
    var hasViews: Bool { self == .wallhaven || self == .pixabay }
    /// Whether the text field is sent to the server (otherwise it filters locally).
    var hasServerSearch: Bool { ![.aerials, .bing, .wallpaperscraft].contains(self) }

    var apiKey: String? {
        guard needsKey else { return nil }
        let key = UserDefaults.standard.string(forKey: "apiKey.\(rawValue)")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// Headers for API calls that need the key in a header.
    var authHeaders: [String: String] {
        guard let key = apiKey else { return [:] }
        switch self {
        case .pexels: return ["Authorization": key]
        case .unsplash: return ["Authorization": "Client-ID \(key)"]
        default: return [:]
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "enabled.\(rawValue)") as? Bool ?? true
    }

    var isReady: Bool { isEnabled && (!needsKey || apiKey != nil) }
}

/// A wallpaper offered by an online source.
struct RemoteWallpaper: Identifiable, Hashable, Sendable {
    var id: String { "\(source.rawValue):\(remoteID)" }
    let source: SourceID
    let remoteID: String
    let kind: WallpaperItem.Kind
    let title: String
    var author: String? = nil
    var pageURL: URL? = nil
    let thumbURL: URL
    /// Small streamable clip for hover previews.
    var previewVideoURL: URL? = nil
    let downloadURL: URL
    let fileExtension: String
    let width: Int
    let height: Int
    var duration: Double? = nil
    var views: Int? = nil
    var favorites: Int? = nil
    var downloads: Int? = nil
    var fileSize: Int? = nil
    var createdAt: Date? = nil
    var tags: [String] = []
    var colors: [String] = []
    /// Licence line for openly licensed sources (Openverse, Commons).
    var license: String? = nil
    /// Endpoint the source asks to be called when a file is downloaded (Unsplash).
    var pingURL: URL? = nil

    var isPortrait: Bool { height > width }
    var pixels: Int { width * height }

    var resolutionLabel: String { width > 0 ? Self.resolutionLabel(width: width, height: height) : "HD" }

    static func resolutionLabel(width: Int, height: Int) -> String {
        let long = max(width, height), short = min(width, height)
        switch (long, short) {
        case (5120..., _), (_, 2880...): return "5K+"
        case (3840..., _), (_, 2160...): return "4K"
        case (2560..., _), (_, 1440...): return "QHD"
        case (1920..., _), (_, 1080...): return "Full HD"
        default: return "\(width)×\(height)"
        }
    }
}

// MARK: - Query

struct CatalogQuery: Hashable, Sendable {
    enum KindFilter: String, CaseIterable, Identifiable, Sendable {
        case all, video, image
        var id: String { rawValue }
        var title: String { switch self { case .all: "Все"; case .video: "Видео"; case .image: "Фото" } }
        func allows(_ k: WallpaperItem.Kind) -> Bool {
            switch self { case .all: true; case .video: k == .video; case .image: k == .image }
        }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case popular, favorites, top, latest, random
        var id: String { rawValue }
        var title: String {
            switch self {
            case .popular: "По просмотрам"
            case .favorites: "По лайкам и избранному"
            case .top: "Топ за период"
            case .latest: "Новые"
            case .random: "Случайные"
            }
        }
        var symbol: String {
            switch self {
            case .popular: "eye"
            case .favorites: "heart"
            case .top: "trophy"
            case .latest: "clock"
            case .random: "shuffle"
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable, Sendable {
        case day = "1d", threeDays = "3d", week = "1w", month = "1M", threeMonths = "3M", halfYear = "6M", year = "1y"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: "За день"
            case .threeDays: "За 3 дня"
            case .week: "За неделю"
            case .month: "За месяц"
            case .threeMonths: "За 3 месяца"
            case .halfYear: "За полгода"
            case .year: "За год"
            }
        }
        var interval: TimeInterval {
            let d: Double = 86_400
            switch self {
            case .day: return d
            case .threeDays: return 3 * d
            case .week: return 7 * d
            case .month: return 30 * d
            case .threeMonths: return 91 * d
            case .halfYear: return 182 * d
            case .year: return 365 * d
            }
        }
    }

    enum Resolution: Int, CaseIterable, Identifiable, Sendable {
        case any = 0, fullHD = 1080, qhd = 1440, uhd = 2160, fiveK = 2880
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .any: "Любое разрешение"
            case .fullHD: "От Full HD"
            case .qhd: "От 1440p"
            case .uhd: "От 4K"
            case .fiveK: "От 5K"
            }
        }
        var size: (w: Int, h: Int) {
            switch self {
            case .any: (0, 0)
            case .fullHD: (1920, 1080)
            case .qhd: (2560, 1440)
            case .uhd: (3840, 2160)
            case .fiveK: (5120, 2880)
            }
        }
    }

    enum Orientation: String, CaseIterable, Identifiable, Sendable {
        case landscape, portrait, any
        var id: String { rawValue }
        var title: String { switch self { case .landscape: "Горизонтальные"; case .portrait: "Вертикальные"; case .any: "Любая ориентация" } }
    }

    static let viewSteps = [0, 1_000, 10_000, 50_000, 100_000, 500_000, 1_000_000]

    var text = ""
    var kind: KindFilter = .all
    var sort: Sort = .popular
    var period: Period = .month
    var minViews = 0
    var resolution: Resolution = .fullHD
    var orientation: Orientation = .landscape
    var maxDuration: Int = 0 // seconds, 0 = any

    var isDefault: Bool { self == CatalogQuery() }

    /// Local check applied on top of whatever the server already filtered.
    func matches(_ w: RemoteWallpaper, serverSearched: Bool) -> Bool {
        guard kind.allows(w.kind) else { return false }
        if minViews > 0 { guard let v = w.views, v >= minViews else { return false } }
        let r = resolution.size
        let knownSize = w.width > 0 && w.height > 0
        if r.w > 0, knownSize {
            let long = max(w.width, w.height), short = min(w.width, w.height)
            guard long >= r.w, short >= r.h else { return false }
        }
        switch orientation {
        case .landscape: guard !knownSize || !w.isPortrait else { return false }
        case .portrait: guard !knownSize || w.isPortrait else { return false }
        case .any: break
        }
        if maxDuration > 0, let d = w.duration, d > Double(maxDuration) { return false }
        if sort == .top, let date = w.createdAt, w.source != .wallhaven,
           date < Date.now.addingTimeInterval(-period.interval) { return false }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        if !serverSearched, !needle.isEmpty {
            let hay = ([w.title, w.author ?? ""] + w.tags).joined(separator: " ").lowercased()
            guard hay.contains(needle) else { return false }
        }
        return true
    }

    /// Client-side ordering, used when results from several sources are merged
    /// or when a source can't sort by the requested key.
    func sorted(_ items: [RemoteWallpaper]) -> [RemoteWallpaper] {
        switch sort {
        case .popular, .top:
            return items.sorted { ($0.views ?? $0.downloads ?? -1) > ($1.views ?? $1.downloads ?? -1) }
        case .favorites:
            return items.sorted { ($0.favorites ?? -1) > ($1.favorites ?? -1) }
        case .latest:
            return items.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .random:
            return items.shuffled()
        }
    }
}

struct ProviderPage: Sendable {
    var items: [RemoteWallpaper]
    var hasMore: Bool
    static let empty = ProviderPage(items: [], hasMore: false)
}

protocol WallpaperProvider: Sendable {
    var source: SourceID { get }
    func fetch(_ query: CatalogQuery, page: Int) async throws -> ProviderPage
}

// MARK: - HTTP

enum RemoteError: LocalizedError {
    case missingKey(SourceID)
    case http(SourceID, Int)
    case rateLimited(SourceID)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let s): "\(s.displayName): добавьте ключ API в настройках (⌘,)."
        case .http(let s, 401), .http(let s, 403): "\(s.displayName): ключ API отклонён. Проверьте его в настройках."
        case .http(let s, let code): "\(s.displayName): сервер ответил \(code)."
        case .rateLimited(let s): "\(s.displayName): слишком много запросов, попробуйте через минуту."
        case .unavailable(let m): m
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.urlCache = URLCache.shared
        cfg.httpAdditionalHeaders = ["User-Agent": "Wallpap/1.1 (macOS)"]
        return URLSession(configuration: cfg)
    }()

    static func json<T: Decodable>(_ type: T.Type, source: SourceID, url: URL,
                                   headers: [String: String] = [:]) async throws -> T {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 429 { throw RemoteError.rateLimited(source) }
            throw RemoteError.http(source, http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func url(_ base: String, _ params: [String: String?]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = params.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
            .sorted { $0.name < $1.name }
        return c.url!
    }
}
