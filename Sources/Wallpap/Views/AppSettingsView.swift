import SwiftUI

/// Settings window: playback (shared with the wallpaper extension), online sources, general.
struct AppSettingsView: View {
    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("Воспроизведение", systemImage: "play.rectangle") }
            SourcesSettings()
                .tabItem { Label("Источники", systemImage: "globe") }
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }
        }
        .frame(width: 560)
    }
}

private struct SourcesSettings: View {
    @Environment(Catalog.self) private var catalog
    @AppStorage("apiKey.pexels") private var pexelsKey = ""
    @AppStorage("apiKey.pixabay") private var pixabayKey = ""
    @AppStorage("apiKey.unsplash") private var unsplashKey = ""
    @AppStorage("wallhaven.categories") private var whCategories = "111"

    var body: some View {
        Form {
            ForEach(SourceID.allCases) { s in
                Section {
                    Toggle(isOn: enabled(s)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.displayName).font(.headline)
                            Text(s.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if s == .pexels { keyField(s, text: $pexelsKey) }
                    if s == .pixabay { keyField(s, text: $pixabayKey) }
                    if s == .unsplash { keyField(s, text: $unsplashKey) }
                    if s == .wallhaven {
                        HStack {
                            Text("Категории")
                            Spacer()
                            categoryToggle("Общие", index: 0)
                            categoryToggle("Аниме", index: 1)
                            categoryToggle("Люди", index: 2)
                        }
                    }
                }
            }
            Section {
                Text("Ключи хранятся локально в настройках приложения (UserDefaults) и отправляются только в API соответствующего сервиса.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .onChange(of: pexelsKey) { catalog.reload() }
        .onChange(of: pixabayKey) { catalog.reload() }
        .onChange(of: unsplashKey) { catalog.reload() }
        .onChange(of: whCategories) { catalog.reload() }
    }

    private func enabled(_ s: SourceID) -> Binding<Bool> {
        Binding(get: { s.isEnabled }, set: {
            UserDefaults.standard.set($0, forKey: "enabled.\(s.rawValue)")
            catalog.reload()
        })
    }

    private func keyField(_ s: SourceID, text: Binding<String>) -> some View {
        HStack {
            SecureField("Ключ API", text: text, prompt: Text("Вставьте ключ \(s.displayName)"))
            if let u = s.keyURL { Link("Получить ключ", destination: u).font(.callout) }
        }
    }

    private func categoryToggle(_ title: String, index: Int) -> some View {
        Toggle(title, isOn: Binding(
            get: { Array(whCategories).indices.contains(index) && Array(whCategories)[index] == "1" },
            set: { on in
                var chars = Array(whCategories.count == 3 ? whCategories : "111")
                chars[index] = on ? "1" : "0"
                let next = String(chars)
                whCategories = next == "000" ? "100" : next
            }))
        .toggleStyle(.checkbox)
    }
}

private struct GeneralSettings: View {
    @State private var cacheSize = URLCache.shared.currentDiskUsage

    var body: some View {
        Form {
            Section("Хранилище") {
                LabeledContent("Коллекция") {
                    Button("Показать в Finder") { NSWorkspace.shared.open(Library.itemsDir) }
                }
                LabeledContent("Кэш превью каталога") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Очистить") {
                            URLCache.shared.removeAllCachedResponses()
                            cacheSize = URLCache.shared.currentDiskUsage
                        }
                    }
                }
            }
            Section("Система") {
                LabeledContent("Обои macOS") {
                    Button("Открыть настройки обоев", action: openWallpaperSettings)
                }
                Text("Видео ставится в слот Aerial «\(SystemWallpaper.slotDisplayName)» и проигрывается самой macOS: приложение можно закрыть.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
    }
}
