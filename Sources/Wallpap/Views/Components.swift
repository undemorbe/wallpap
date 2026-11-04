import AVFoundation
import AppKit
import SwiftUI

// MARK: - Motion

extension Animation {
    /// Critically damped default: no overshoot, interruptible.
    static let ui = Animation.spring(response: 0.32, dampingFraction: 1)
}

// MARK: - Formatting

extension Int {
    /// 12 345 → "12,3 тыс."
    var compact: String { formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
}

extension Double {
    /// 75 → "1:15"
    var clock: String {
        let s = Int(rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Images

/// Local thumbnail with an in-memory cache (the grid re-creates views while scrolling).
struct Thumbnail: View {
    let url: URL
    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        if let image = Self.load(url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    static func load(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// Remote thumbnail; the placeholder takes the picture's dominant colour when known.
struct RemoteImage: View {
    let url: URL
    var tint: Color?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
            case .failure:
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
            default:
                Rectangle().fill(tint?.opacity(0.35) ?? Color.primary.opacity(0.06))
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Video

/// Muted looping preview (local file or streamable remote clip).
struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            layer = CALayer()
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateNSView(_ nsView: PlayerView, context: Context) {}
    static func dismantleNSView(_ nsView: PlayerView, coordinator: ()) { nsView.player.pause() }
}

// MARK: - Card

/// Picture frame shared by library and catalog cards: continuous corners, no border at rest,
/// an accent ring when selected, a gentle lift while hovered.
struct MediaFrame<Content: View>: View {
    let isSelected: Bool
    let hovering: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(isSelected ? 4 : 0)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 14, y: 6)
            .scaleEffect(hovering && !isSelected ? 1.02 : 1)
            .animation(.ui, value: hovering)
            .animation(.ui, value: isSelected)
    }
}

/// Small glass chip on top of a picture (video length, "on desktop").
struct GlassChip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.25), in: Capsule())
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// Round glass button shown over a picture on hover.
struct GlassIconButton: View {
    let symbol: String
    var tint: Color = .white
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// iOS-like press feedback: shrinks on press, springs back.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Two lines under a card picture: title, then one quiet line of facts.
struct CardCaption: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Inspector building blocks

/// Inset group like iOS Settings: rows on a tone step, no separators.
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct InspectorHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.bold))
                .tracking(-0.3)
                .lineLimit(3)
                .textSelection(.enabled)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Full-width capsule primary action.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
    }
    func secondaryAction() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
    }
}

func openWallpaperSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}
