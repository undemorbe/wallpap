import AppKit
import SwiftUI

struct WallpapApp: App {
    @State private var library = Library()
    @State private var settings = SettingsStore()
    @State private var catalog = Catalog()

    init() {
        // Catalog thumbnails: keep them around between launches.
        URLCache.shared = URLCache(memoryCapacity: 96 << 20, diskCapacity: 768 << 20)
    }

    var body: some Scene {
        Window("Wallpap", id: "main") {
            ContentView()
                .environment(library)
                .environment(catalog)
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Каталог") {
                Button("Обновить") { catalog.reload() }.keyboardShortcut("r")
                Button("Загрузить ещё") { catalog.loadMore() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Сбросить фильтры") { catalog.query = CatalogQuery() }
            }
        }

        Settings {
            AppSettingsView()
                .environment(settings)
                .environment(catalog)
        }
    }
}

/// Wallpap --catalog <source|all> [--sort popular|favorites|top|latest|random]
///         [--kind video|image] [--min-views N] [--query text]
@MainActor
func runCatalogQuery(_ args: [String]) async -> Int32 {
    func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    var q = CatalogQuery()
    if let s = value("--sort").flatMap(CatalogQuery.Sort.init(rawValue:)) { q.sort = s }
    if let k = value("--kind").flatMap(CatalogQuery.KindFilter.init(rawValue:)) { q.kind = k }
    if let v = value("--min-views").flatMap(Int.init) { q.minViews = v }
    if let t = value("--query") { q.text = t }
    let raw = value("--catalog") ?? "all"
    let sources = raw == "all" ? SourceID.allCases.filter(\.isReady) : [SourceID(rawValue: raw)].compactMap { $0 }
    guard !sources.isEmpty else { print("Неизвестный источник: \(raw)"); return 64 }
    var all: [RemoteWallpaper] = []
    for s in sources {
        do {
            let page = try await Providers.make(s).fetch(q, page: 1)
            let kept = page.items.filter { q.matches($0, serverSearched: s.hasServerSearch) }
            print("\(s.displayName): получено \(page.items.count), после фильтров \(kept.count), ещё: \(page.hasMore)")
            all += kept
        } catch {
            print("\(s.displayName): \(error.localizedDescription)")
        }
    }
    for w in q.sorted(all).prefix(12) {
        let stats = [w.views.map { "views \($0)" }, w.favorites.map { "fav \($0)" }, w.duration.map { "\(Int($0))s" }]
            .compactMap { $0 }.joined(separator: " ")
        print("  [\(w.source.rawValue)] \(w.kind.rawValue) \(w.width)x\(w.height) \(stats) — \(w.title)")
    }
    return 0
}

/// Headless mode for scripting:
///   Wallpap --import <file> [--apply]
///   Wallpap --apply <name>
///   Wallpap --reset-slot
@MainActor
func runCommandLine(_ args: [String]) async -> Int32 {
    let library = Library()
    if args.contains("--reset-slot") {
        library.resetSystemSlot()
        print("Слот очищен")
        return 0
    }
    if let i = args.firstIndex(of: "--apply"), i + 1 < args.count, !args.contains("--import") {
        let query = args[i + 1].lowercased()
        guard let item = library.items.first(where: { $0.name.lowercased().contains(query) }) else {
            print("Не найдено в библиотеке: \(args[i + 1])")
            return 1
        }
        await library.apply(item)
        if let err = library.errorMessage { print("Ошибка: \(err)"); return 1 }
        print("Установлено как фон: \(item.name)")
        return 0
    }
    guard let i = args.firstIndex(of: "--import"), i + 1 < args.count else {
        print("Использование: Wallpap --import <файл> [--apply] | --apply <название> | --reset-slot")
        return 64
    }
    let url = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    guard let item = await library.importFile(url) else {
        print("Ошибка: \(library.errorMessage ?? "неизвестно")")
        return 1
    }
    print("Импортировано: \(item.name) [\(item.kind.rawValue)]")
    if args.contains("--apply") {
        await library.apply(item)
        if let err = library.errorMessage { print("Ошибка: \(err)"); return 1 }
        print("Установлено как фон")
    }
    return 0
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.contains("--catalog") {
    Task { @MainActor in exit(await runCatalogQuery(cliArgs)) }
    dispatchMain()
} else if cliArgs.contains("--import") || cliArgs.contains("--apply") || cliArgs.contains("--reset-slot") {
    Task { @MainActor in exit(await runCommandLine(cliArgs)) }
    dispatchMain()
} else {
    WallpapApp.main()
}
