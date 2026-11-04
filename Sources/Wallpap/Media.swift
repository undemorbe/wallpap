import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum MediaError: LocalizedError {
    case noVideoTrack
    case exportUnavailable
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "В файле нет видеодорожки."
        case .exportUnavailable: return "Не удалось подготовить экспорт в HEVC."
        case .unreadableImage: return "Не удалось прочитать изображение."
        }
    }
}

enum Media {
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
    static let imageTypes: [UTType] = [.image, .heic, .jpeg, .png]

    static func isVideo(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .movie) || t.conforms(to: .video)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }

    /// Re-encodes a video to HEVC QuickTime without audio — the format the Aerial player expects.
    static func transcodeVideo(from source: URL, to destination: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.noVideoTrack }
        let duration = try await asset.load(.duration)
        let transform = try await track.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.exportUnavailable }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        videoTrack.preferredTransform = transform

        // Already HEVC: just drop audio and remux, no re-encode (Apple Aerials, many 4K clips).
        let formats = try await track.load(.formatDescriptions)
        let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        let preset = isHEVC ? AVAssetExportPresetPassthrough : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset)
        else { throw MediaError.exportUnavailable }
        session.shouldOptimizeForNetworkUse = true

        try? FileManager.default.removeItem(at: destination)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: destination, as: .mov)
        progress(1)
    }

    static func videoFrame(_ url: URL, at seconds: Double = 1) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }

    static func imageThumbnail(_ url: URL, maxPixel: Int = 1280) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { throw MediaError.unreadableImage }
        return img
    }

    /// Writes a PNG, optionally aspect-filling (center crop) into `fill` size.
    static func writePNG(_ image: CGImage, to url: URL, fill: CGSize? = nil) throws {
        var output = image
        if let fill {
            let w = Int(fill.width), h = Int(fill.height)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                let scale = max(fill.width / CGFloat(image.width), fill.height / CGFloat(image.height))
                let dw = CGFloat(image.width) * scale, dh = CGFloat(image.height) * scale
                ctx.draw(image, in: CGRect(x: (fill.width - dw) / 2, y: (fill.height - dh) / 2, width: dw, height: dh))
                if let scaled = ctx.makeImage() { output = scaled }
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MediaError.unreadableImage }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else { throw MediaError.unreadableImage }
    }
}
