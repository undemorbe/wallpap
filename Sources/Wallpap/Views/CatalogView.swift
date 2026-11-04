import AppKit
import SwiftUI

struct CatalogView: View {
    @Environment(Library.self) private var library
    @Environment(Catalog.self) private var catalog
    @Binding var selection: RemoteWallpaper?
    @Binding var showInspector: Bool
    @Environment(\.openSettings) private var openSettings
    @State private var showFilters = false

    var body: some View {
        @Bindable var catalog = catalog
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { controls }
            .searchable(text: $catalog.query.text, placement: .toolbar,
                        prompt: catalog.source.map { "Поиск в \($0.displayName)" } ?? "Поиск обоев")
            .inspector(isPresented: $showInspector) {
                Group {
                    if let selection { RemoteInspector(item: selection) }
                    else { ContentUnavailableView("Ничего не выбрано", systemImage: "rectangle.on.rectangle",
                                                  description: Text("Выберите обои, чтобы увидеть подробности.")) }
                }
                .inspectorColumnWidth(min: 270, ideal: 310, max: 420)
            }
    }

    @ViewBuilder private var content: some View {
        if catalog.items.isEmpty {
            if catalog.isLoading {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(catalog.source?.displayName ?? "Ничего не найдено", systemImage: catalog.source?.symbol ?? "magnifyingglass")
                } description: {
                    Text(catalog.notices.values.first ?? catalog.emptyReason)
                } actions: {
                    if let s = catalog.source, s.needsKey, s.apiKey == nil {
                        Button("Добавить ключ") { openSettings() }.primaryAction()
                        if let u = s.keyURL { Link("Получить бесплатный ключ", destination: u) }
                    } else if !catalog.query.isDefault {
                        Button("Сбросить фильтры") { catalog.query = CatalogQuery() }.secondaryAction()
                    } else {
                        Button("Обновить") { catalog.reload() }.secondaryAction()
                    }
                }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            if !catalog.notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(catalog.notices.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { _, msg in
                        Label(msg, systemImage: "exclamationmark.circle")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 20)], spacing: 26) {
                ForEach(catalog.items) { item in
                    RemoteCard(item: item, isSelected: selection?.id == item.id)
                        .onTapGesture(count: 2) { Task { await library.downloadAndApply(item) } }
                        .simultaneousGesture(TapGesture().onEnded { selection = item })
                        .contextMenu { RemoteActions(item: item) }
                        .onAppear { if item.id == catalog.items.last?.id { catalog.loadMore() } }
                }
            }
            .padding(24)

            if catalog.isLoading {
                ProgressView().padding(.bottom, 28)
            } else if catalog.canLoadMore {
                Button("Показать ещё") { catalog.loadMore() }.secondaryAction().padding(.bottom, 28)
            }
        }
    }

    // MARK: Controls: one segmented control, sort, and everything else behind "Фильтры"

    private var controls: some View {
        @Bindable var catalog = catalog
        let kinds = catalog.source.map { s in CatalogQuery.KindFilter.allCases.filter { $0 == .all || s.kinds.contains(where: $0.allows) } }
            ?? CatalogQuery.KindFilter.allCases
        return HStack(spacing: 10) {
            if kinds.count > 2 {
                Picker("Тип", selection: $catalog.query.kind) {
                    ForEach(kinds) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Сортировка", selection: $catalog.query.sort) {
                    ForEach(CatalogQuery.Sort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                if catalog.query.sort == .top {
                    Picker("Период", selection: $catalog.query.period) {
                        ForEach(CatalogQuery.Period.allCases) { Text($0.title).tag($0) }
                    }
                }
            } label: {
                Label(catalog.query.sort == .top ? "Топ: \(catalog.query.period.title.lowercased())" : catalog.query.sort.title,
                      systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .fixedSize()

            Button { showFilters.toggle() } label: {
                Label(filterCount == 0 ? "Фильтры" : "Фильтры · \(filterCount)",
                      systemImage: filterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .foregroundStyle(filterCount == 0 ? Color.primary : Color.accentColor)
            .popover(isPresented: $showFilters, arrowEdge: .bottom) { FiltersPopover() }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.background)
    }

    /// Filters that differ from the defaults (shown on the button).
    private var filterCount: Int {
        let q = catalog.query, d = CatalogQuery()
        return [q.minViews != d.minViews, q.resolution != d.resolution,
                q.orientation != d.orientation, q.maxDuration != d.maxDuration].filter { $0 }.count
    }
}

private struct FiltersPopover: View {
    @Environment(Catalog.self) private var catalog

    var body: some View {
        @Bindable var catalog = catalog
        let q = catalog.query
        Form {
            Picker("Просмотры", selection: $catalog.query.minViews) {
                ForEach(CatalogQuery.viewSteps, id: \.self) { Text($0 == 0 ? "Любые" : "от \($0.compact)").tag($0) }
            }
            Picker("Разрешение", selection: $catalog.query.resolution) {
                ForEach(CatalogQuery.Resolution.allCases) { Text($0.title).tag($0) }
            }
            Picker("Ориентация", selection: $catalog.query.orientation) {
                ForEach(CatalogQuery.Orientation.allCases) { Text($0.title).tag($0) }
            }
            if q.kind != .image {
                Picker("Длина видео", selection: $catalog.query.maxDuration) {
                    ForEach([0, 15, 30, 60, 120], id: \.self) {
                        Text($0 == 0 ? "Любая" : ($0 < 60 ? "до \($0) с" : "до \($0 / 60) мин")).tag($0)
                    }
                }
            }
            if q.minViews > 0 {
                Text("Просмотры сообщают только Wallhaven и Pixabay. Обои из остальных источников будут скрыты.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !q.isDefault {
                Button("Сбросить всё") { catalog.query = CatalogQuery() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Card

struct RemoteCard: View {
    @Environment(Library.self) private var library
    let item: RemoteWallpaper
    let isSelected: Bool
    @State private var hovering = false

    private var downloaded: Bool { library.item(for: item) != nil }
    private var job: Library.Job? { library.jobs.first { $0.remoteID == item.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaFrame(isSelected: isSelected, hovering: hovering) {
                ZStack {
                    RemoteImage(url: item.thumbURL, tint: item.colors.first.flatMap(Color.init(hex:)))
                    if hovering, let clip = item.previewVideoURL {
                        LoopingVideo(url: clip).transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video { GlassChip(text: item.duration?.clock ?? "Видео", symbol: "play.fill").padding(8) }
                }
                .overlay(alignment: .bottomTrailing) { action.padding(8) }
            }
            CardCaption(title: item.title, detail: detail)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.title)
    }

    private var detail: String {
        var parts: [String] = []
        if let v = item.views { parts.append("\(v.compact) просм.") }
        else if let d = item.downloads { parts.append("\(d.compact) загр.") }
        if let f = item.favorites, item.views == nil { parts.append("♥ \(f.compact)") }
        parts.append(item.resolutionLabel)
        parts.append(item.author ?? item.source.displayName)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var action: some View {
        if let job {
            ProgressView(value: job.progress ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        } else if downloaded {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.green, in: Circle())
                .help("Уже в коллекции")
        } else if hovering {
            GlassIconButton(symbol: "arrow.down", help: "Скачать в коллекцию") {
                Task { await library.download(item) }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

struct RemoteActions: View {
    @Environment(Library.self) private var library
    let item: RemoteWallpaper

    var body: some View {
        Button("Скачать и установить", systemImage: "desktopcomputer") { Task { await library.downloadAndApply(item) } }
        Button("Скачать в коллекцию", systemImage: "arrow.down.circle") { Task { await library.download(item) } }
            .disabled(library.item(for: item) != nil)
        if let page = item.pageURL {
            Divider()
            Button("Открыть на \(item.source.displayName)", systemImage: "safari") { NSWorkspace.shared.open(page) }
            Button("Скопировать ссылку", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.absoluteString, forType: .string)
            }
        }
    }
}

// MARK: - Inspector

struct RemoteInspector: View {
    @Environment(Library.self) private var library
    let item: RemoteWallpaper

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RemoteImage(url: item.thumbURL, tint: item.colors.first.flatMap(Color.init(hex:)))
                    if let clip = item.previewVideoURL { LoopingVideo(url: clip).id(clip) }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                InspectorHeader(title: item.title,
                                subtitle: [item.author, item.source.displayName].compactMap { $0 }.joined(separator: " · "))

                actions

                if item.views != nil || item.favorites != nil || item.downloads != nil {
                    HStack(spacing: 0) {
                        if let v = item.views { metric(v, "просмотров") }
                        if let f = item.favorites { metric(f, item.source == .wallhaven ? "в избранном" : "лайков") }
                        if let d = item.downloads { metric(d, "загрузок") }
                    }
                }

                InsetGroup {
                    InfoRow(label: "Тип", value: item.kind == .video ? "Видео" : "Фото")
                    InfoRow(label: "Разрешение", value: "\(item.width) × \(item.height)")
                    if let d = item.duration { InfoRow(label: "Длительность", value: d.clock) }
                    if let s = item.fileSize {
                        InfoRow(label: "Размер", value: ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
                    }
                    if let c = item.createdAt { InfoRow(label: "Добавлено", value: c.formatted(date: .abbreviated, time: .omitted)) }
                }

                if !item.colors.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.colors, id: \.self) { hex in
                            Circle().fill(Color(hex: hex) ?? .gray).frame(width: 22, height: 22).help(hex)
                        }
                    }
                }

                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }

    private func metric(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.compact).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        let local = library.item(for: item)
        let job = library.jobs.first { $0.remoteID == item.id }
        VStack(spacing: 8) {
            if let job {
                ProgressView(value: job.progress ?? 0) { Text("Загрузка").font(.callout) }
            } else if let local {
                Button { Task { await library.apply(local) } } label: {
                    Text(library.activeID == local.id ? "Уже на рабочем столе" : "Установить").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .disabled(library.activeID == local.id)
            } else {
                Button { Task { await library.downloadAndApply(item) } } label: {
                    Text("Установить").frame(maxWidth: .infinity)
                }
                .primaryAction()
                Button { Task { await library.download(item) } } label: {
                    Text("Только скачать").frame(maxWidth: .infinity)
                }
                .secondaryAction()
            }
            if let page = item.pageURL {
                Link(destination: page) {
                    Label("Открыть на \(item.source.displayName)", systemImage: "arrow.up.right")
                        .font(.callout)
                }
                .padding(.top, 2)
            }
        }
    }
}
