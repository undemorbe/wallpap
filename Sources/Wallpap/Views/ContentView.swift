import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case library(LibraryFilter)
    case catalog(SourceID?)
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Catalog.self) private var catalog
    @Environment(\.openSettings) private var openSettings

    @SceneStorage("sidebar") private var sidebarRaw = "library.all"
    @State private var localSelection: WallpaperItem.ID?
    @State private var remoteSelection: RemoteWallpaper?
    @AppStorage("showInspector") private var showInspector = true
    @State private var showImporter = false
    @State private var isDropTargeted = false

    private var sidebar: Binding<SidebarItem?> {
        Binding(get: { Self.decode(sidebarRaw) }, set: { if let v = $0 { sidebarRaw = Self.encode(v) } })
    }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                            .overlay { Label("Добавить в коллекцию", systemImage: "plus.circle.fill").font(.title2.weight(.semibold)) }
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !library.jobs.isEmpty || library.activeID != nil {
                        StatusCapsule().transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .frame(minWidth: 920, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Добавить файлы", systemImage: "plus") }
                    .help("Добавить видео или изображение с диска")
                Menu {
                    Button("Открыть «Обои» в Системных настройках", action: openWallpaperSettings)
                    Button("Показать папку коллекции") { NSWorkspace.shared.open(Library.itemsDir) }
                    Button("Настройки источников…") { openSettings() }
                    Divider()
                    Button("Убрать видео из системного слота", role: .destructive) { library.resetSystemSlot() }
                } label: { Label("Ещё", systemImage: "ellipsis.circle") }
                Button { withAnimation(.ui) { showInspector.toggle() } } label: {
                    Label("Инспектор", systemImage: "sidebar.right")
                }
                .help("Показать или скрыть подробности")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Media.videoTypes + Media.imageTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { await library.importFiles(await fileURLs(from: providers)) }
            return true
        }
        .alert("Ошибка", isPresented: Binding(get: { library.errorMessage != nil },
                                              set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.errorMessage ?? "") }
    }

    // MARK: Sidebar

    private var sidebarList: some View {
        List(selection: sidebar) {
            Section("Коллекция") {
                ForEach(LibraryFilter.allCases) { f in
                    Label(f.title, systemImage: f.symbol)
                        .badge(library.items.filter(f.allows).count)
                        .tag(SidebarItem.library(f))
                }
            }
            Section("Каталог") {
                Label("Все источники", systemImage: "globe")
                    .tag(SidebarItem.catalog(nil))
                ForEach(SourceID.allCases.filter(\.isEnabled)) { s in
                    HStack {
                        Label(s.displayName, systemImage: s.symbol)
                        Spacer()
                        if s.needsKey, s.apiKey == nil {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                                .help("Нужен ключ API — добавьте его в настройках")
                        }
                    }
                    .tag(SidebarItem.catalog(s))
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch sidebar.wrappedValue ?? .library(.all) {
        case .library(let f):
            LibraryView(filter: f, selection: $localSelection, showInspector: $showInspector,
                        onImport: { showImporter = true },
                        onBrowse: { sidebarRaw = Self.encode(.catalog(nil)) })
                .navigationTitle(f.title)
                .navigationSubtitle("\(library.items.filter(f.allows).count) в коллекции")
        case .catalog(let s):
            CatalogView(selection: $remoteSelection, showInspector: $showInspector)
                .navigationTitle(s?.displayName ?? "Каталог")
                .navigationSubtitle(catalog.items.isEmpty ? "" : "\(catalog.items.count) найдено")
                .task(id: s) { catalog.show(s) }
        }
    }

    // MARK: Helpers

    static func encode(_ item: SidebarItem) -> String {
        switch item {
        case .library(let f): "library.\(f.rawValue)"
        case .catalog(let s): "catalog.\(s?.rawValue ?? "all")"
        }
    }

    static func decode(_ raw: String) -> SidebarItem? {
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "library": return LibraryFilter(rawValue: parts[1]).map { .library($0) }
        case "catalog": return .catalog(SourceID(rawValue: parts[1]))
        default: return nil
        }
    }

    private func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }) { urls.append(url) }
        }
        return urls
    }
}

// MARK: - Status capsule

/// Floating capsule: download/import progress, or what is on the desktop now.
struct StatusCapsule: View {
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            if let job = library.jobs.last {
                HStack(spacing: 10) {
                    ProgressView(value: job.progress ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(job.title).lineLimit(1)
                    if let p = job.progress { Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary) }
                    if library.jobs.count > 1 { Text("+\(library.jobs.count - 1)").foregroundStyle(.secondary) }
                }
            } else if let active = library.items.first(where: { $0.id == library.activeID }) {
                HStack(spacing: 10) {
                    Thumbnail(url: active.thumbURL)
                        .frame(width: 30, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(active.name).fontWeight(.medium).lineLimit(1)
                    Text("на рабочем столе").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 460)
        .padding(.bottom, 16)
        .animation(.ui, value: library.jobs.count)
    }
}
