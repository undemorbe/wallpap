import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Анимировать на рабочем столе", isOn: $store.settings.animateOnDesktop)
                Toggle("Анимировать на экране блокировки", isOn: $store.settings.animateOnLockScreen)
            } header: {
                Text("Анимация")
            } footer: {
                Text("Если анимация выключена, на экране остаётся текущий кадр видео.")
            }

            Section("Экономия энергии") {
                Toggle("Пауза, когда рабочий стол не виден", isOn: $store.settings.pauseWhenHidden)
                    .help("Например, когда окно развёрнуто на весь экран или дисплей спит")
                Toggle("Пауза при работе от аккумулятора", isOn: $store.settings.pauseOnBattery)
                Toggle("Пауза в режиме энергосбережения", isOn: $store.settings.pauseInLowPowerMode)
            }

            Section("Воспроизведение") {
                LabeledContent("Скорость") {
                    HStack {
                        Slider(value: $store.settings.playbackSpeed, in: 0.25...2, step: 0.25)
                            .frame(width: 180)
                        Text(store.settings.playbackSpeed, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Text("×").foregroundStyle(.secondary)
                    }
                }
                Picker("Масштаб", selection: $store.settings.scaling) {
                    ForEach(PlaybackSettings.Scaling.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                HStack {
                    Text("Настройки применяются сразу, приложение можно закрыть.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("По умолчанию") { store.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
