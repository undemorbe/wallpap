import AppKit
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable, Hashable {
    case all, video, image, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Все обои"
        case .video: "Видео"
        case .image: "Фото"
        case .favorites: "Избранное"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .video: "play.rectangle"
        case .image: "photo"
        case .favorites: "heart"
        }
    }
    func allows(_ item: WallpaperItem) -> Bool {
        switch self {
        case .all: true
        case .video: item.kind == .video
        case .image: item.kind == .image
        case .favorites: item.favorite
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case added, name, resolution, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: "Сначала новые"
        case .name: "По названию"
        case .resolution: "По разрешению"
        case .kind: "Сначала видео"
        }
    }
}

struct LibraryView: View {
    @Environment(Library.self) private var library
    let filter: LibraryFilter
    @Binding var selection: WallpaperItem.ID?
    @Binding var showInspector: Bool
    let onImport: () -> Void
    let onBrowse: () -> Void

    @State private var search = ""
    @AppStorage("library.sort") private var sort: LibrarySort = .added
    @State private var renaming: WallpaperItem?
    @State private var renameText = ""
    @State private var confirmDelete: WallpaperItem?

    private var visible: [WallpaperItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = library.items.filter { item in
            filter.allows(item) && (needle.isEmpty
                || item.name.lowercased().contains(needle)
                || (item.author?.lowercased().contains(needle) ?? false)
                || (item.source?.displayName.lowercased().contains(needle) ?? false))
        }
        switch sort {
        case .added: return list.sorted { $0.addedAt > $1.addedAt }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .resolution: return list.sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
        case .kind: return list.sorted { ($0.kind == .video ? 0 : 1, $1.addedAt) < ($1.kind == .video ? 0 : 1, $0.addedAt) }
        }
    }

    private var selectedItem: WallpaperItem? { library.items.first { $0.id == selection } }

    var body: some View {
        Group {
            if library.items.isEmpty {
                ContentUnavailableView {
                    Label("Коллекция пуста", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Перетащите сюда видео или фото, или найдите обои в каталоге.")
                } actions: {
                    Button("Открыть каталог", action: onBrowse).primaryAction()
                    Button("Выбрать файлы…", action: onImport).buttonStyle(.link)
                }
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search.isEmpty ? filter.title : search)
            } else {
                grid
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Поиск в коллекции")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Сортировка", systemImage: "arrow.up.arrow.down") }
                .help("Сортировка коллекции")
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let item = selectedItem {
                    LocalInspector(item: item, onRename: startRename, onDelete: { confirmDelete = $0 })
                } else {
                    ContentUnavailableView("Ничего не выбрано", systemImage: "rectangle.on.rectangle",
                                           description: Text("Выберите обои в коллекции."))
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Сохранить") { if let r = renaming { library.rename(r, to: renameText) } }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить «\(confirmDelete?.name ?? "")» из коллекции?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let d = confirmDelete { library.delete(d); if selection == d.id { selection = nil } }
            }
        } message: { Text("Файл будет удалён из коллекции. Текущий фон рабочего стола останется.") }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 20)], spacing: 26) {
                ForEach(visible) { item in
                    WallpaperCard(item: item,
                                  isSelected: selection == item.id,
                                  isActive: library.activeID == item.id)
                        .onTapGesture(count: 2) { Task { await library.apply(item) } }
                        .simultaneousGesture(TapGesture().onEnded { selection = item.id })
                        .contextMenu {
                            Button("Установить как фон") { Task { await library.apply(item) } }
                            Button(item.favorite ? "Убрать из избранного" : "В избранное") { library.toggleFavorite(item) }
                            Button("Переименовать…") { startRename(item) }
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                            if let page = item.pageURL {
                                Button("Открыть источник") { NSWorkspace.shared.open(page) }
                            }
                            Divider()
                            Button("Удалить…", role: .destructive) { confirmDelete = item }
                        }
                }
            }
            .padding(24)
        }
    }

    private func startRename(_ item: WallpaperItem) {
        renameText = item.name
        renaming = item
    }
}

// MARK: - Card

struct WallpaperCard: View {
    @Environment(Library.self) private var library
    let item: WallpaperItem
    let isSelected: Bool
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaFrame(isSelected: isSelected, hovering: hovering) {
                ZStack {
                    Thumbnail(url: item.thumbURL)
                    if hovering, item.kind == .video {
                        LoopingVideo(url: item.fileURL).transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        GlassChip(text: item.duration?.clock ?? "Видео", symbol: "play.fill").padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isActive { GlassChip(text: "На рабочем столе", symbol: "checkmark").padding(8) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.favorite || hovering {
                        GlassIconButton(symbol: item.favorite ? "heart.fill" : "heart",
                                        tint: item.favorite ? .pink : .white,
                                        help: item.favorite ? "Убрать из избранного" : "В избранное") {
                            library.toggleFavorite(item)
                        }
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
            }
            CardCaption(title: item.name, detail: detail)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var detail: String {
        var parts: [String] = []
        if let r = item.resolutionLabel { parts.append(r) }
        if let s = item.source { parts.append(s.displayName) }
        parts.append(item.addedAt.formatted(.dateTime.day().month(.abbreviated)))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Inspector

struct LocalInspector: View {
    @Environment(Library.self) private var library
    let item: WallpaperItem
    let onRename: (WallpaperItem) -> Void
    let onDelete: (WallpaperItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Thumbnail(url: item.thumbURL)
                    if item.kind == .video { LoopingVideo(url: item.fileURL).id(item.id) }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(alignment: .top) {
                    InspectorHeader(title: item.name,
                                    subtitle: [item.kind == .video ? "Видео" : "Фото", item.author, item.source?.displayName]
                                        .compactMap { $0 }.joined(separator: " · "))
                    Button { library.toggleFavorite(item) } label: {
                        Image(systemName: item.favorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(item.favorite ? Color.pink : Color.secondary)
                    }
                    .buttonStyle(PressableStyle())
                    .help(item.favorite ? "Убрать из избранного" : "В избранное")
                }

                Button { Task { await library.apply(item) } } label: {
                    Text(library.activeID == item.id ? "Уже на рабочем столе" : "Установить").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .disabled(library.activeID == item.id || library.jobs.contains { $0.remoteID == nil })

                InsetGroup {
                    if let w = item.width, let h = item.height { InfoRow(label: "Разрешение", value: "\(w) × \(h)") }
                    if let d = item.duration { InfoRow(label: "Длительность", value: d.clock) }
                    if let size = try? item.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        InfoRow(label: "Размер", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    InfoRow(label: "Добавлено", value: item.addedAt.formatted(date: .abbreviated, time: .shortened))
                }

                InsetGroup {
                    row("Переименовать", "pencil") { onRename(item) }
                    row("Показать в Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                    if let page = item.pageURL { row("Открыть источник", "arrow.up.right") { NSWorkspace.shared.open(page) } }
                    row("Удалить", "trash", role: .destructive) { onDelete(item) }
                }
            }
            .padding(18)
        }
    }

    private func row(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
        .font(.callout)
    }
}
