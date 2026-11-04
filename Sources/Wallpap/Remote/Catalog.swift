import Foundation
import Observation

/// Browses one or all online sources with paging and filtering.
@MainActor
@Observable
final class Catalog {
    /// `nil` means "all sources".
    private(set) var source: SourceID?
    var query = CatalogQuery() {
        didSet { if query != oldValue { scheduleReload(debounce: query.text != oldValue.text) } }
    }

    private(set) var items: [RemoteWallpaper] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = false
    /// Per-source problems (missing key, network) shown above the grid.
    private(set) var notices: [SourceID: String] = [:]
    /// Items the server returned before local filters, for the "hidden by filters" hint.
    private(set) var fetchedCount = 0

    private var page = 0
    private var exhausted: Set<SourceID> = []
    private var seen: Set<String> = []
    private var loadTask: Task<Void, Never>?

    var activeSources: [SourceID] {
        let list = source.map { [$0] } ?? SourceID.allCases
        return list.filter { s in
            s.isEnabled && (source != nil || !s.needsKey || s.apiKey != nil)
                && s.kinds.contains(where: query.kind.allows)
        }
    }

    func show(_ source: SourceID?) {
        guard source != self.source || items.isEmpty && !isLoading else { return }
        self.source = source
        reload()
    }

    func reload() { scheduleReload(debounce: false) }

    private func scheduleReload(debounce: Bool) {
        loadTask?.cancel()
        items = []
        seen = []
        exhausted = []
        notices = [:]
        page = 0
        fetchedCount = 0
        canLoadMore = false
        isLoading = true // spinner, not "nothing found", while the debounce waits
        loadTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            await self?.fill()
        }
    }

    func loadMore() {
        guard !isLoading, canLoadMore else { return }
        loadTask = Task { [weak self] in await self?.fill() }
    }

    /// Fetches pages until enough items pass the local filters (or sources run dry).
    private func fill() async {
        isLoading = true
        defer { isLoading = false }
        let target = items.count + 24
        var rounds = 0
        while items.count < target, rounds < 5, !Task.isCancelled {
            let sources = activeSources.filter { !exhausted.contains($0) }
            guard !sources.isEmpty else { break }
            page += 1
            rounds += 1
            let q = query, p = page
            let roundStart = items.count
            let keepServerOrder = sources.count == 1 && Self.serverSorts(sources[0], q.sort)
            // Show each source as soon as it answers; a slow one doesn't hold the others back.
            await withTaskGroup(of: (SourceID, Result<ProviderPage, Error>).self) { group in
                for s in sources {
                    group.addTask {
                        do { return (s, .success(try await Providers.make(s).fetch(q, page: p))) }
                        catch { return (s, .failure(error)) }
                    }
                }
                for await (s, result) in group {
                    guard !Task.isCancelled, q == query else { group.cancelAll(); return }
                    switch result {
                    case .success(let pg):
                        if !pg.hasMore { exhausted.insert(s) }
                        fetchedCount += pg.items.count
                        let kept = pg.items.filter { q.matches($0, serverSearched: s.hasServerSearch) && seen.insert($0.id).inserted }
                        items.append(contentsOf: keepServerOrder ? kept : q.sorted(kept))
                    case .failure(let e):
                        exhausted.insert(s)
                        if (e as? URLError)?.code != .cancelled { notices[s] = e.localizedDescription }
                    }
                }
            }
            guard !Task.isCancelled, q == query else { return }
            // Merge this round's sources into one order once everything has arrived.
            if !keepServerOrder, items.count > roundStart, q.sort != .random {
                let round = Array(items[roundStart...])
                items.replaceSubrange(roundStart..., with: q.sorted(round))
            }
        }
        canLoadMore = activeSources.contains { !exhausted.contains($0) }
    }

    private static func serverSorts(_ s: SourceID, _ sort: CatalogQuery.Sort) -> Bool {
        switch s {
        case .wallhaven: true
        case .pixabay: sort == .popular || sort == .latest
        case .commons: sort == .latest || sort == .random
        case .wallpaperscraft: sort != .random
        case .unsplash: sort == .latest
        case .pexels, .aerials, .bing, .openverse, .nasa: sort != .random
        }
    }

    /// Why the list is empty, in human terms.
    var emptyReason: String {
        if activeSources.isEmpty {
            if let s = source, s.needsKey, s.apiKey == nil { return "Для \(s.displayName) нужен бесплатный ключ API." }
            if let s = source, !s.kinds.contains(where: query.kind.allows) {
                return "\(s.displayName) не предлагает \(query.kind == .video ? "видео" : "фото")."
            }
            return "Нет подходящих источников. Включите их в настройках."
        }
        if fetchedCount > 0 { return "Найдено \(fetchedCount), но все скрыты фильтрами. Ослабьте фильтры." }
        return "Ничего не найдено."
    }
}
