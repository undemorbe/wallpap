import AVFoundation
import CoreVideo
import IOSurface
import ImageIO
import QuartzCore

/// One live wallpaper instance (one per display/space the agent asks for).
/// Decodes the video with AVAssetReader and feeds an AVSampleBufferDisplayLayer in a
/// remote CAContext hosted by WallpaperAgent. Playback speed and pausing are driven
/// by the layer's control timebase, so a paused wallpaper keeps showing its current frame.
@MainActor
final class VideoWallpaper {
    let contextID: UInt32
    private let context: NSObject
    private let root = CALayer()
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let timebase: CMTimebase
    private let item: LibraryReader.Item?
    private let feeder: SampleFeeder?
    private var size: CGSize
    private var scale: CGFloat

    // Inputs to the "should animate" decision.
    private var presentationMode = "default"
    private var isActive = true
    private var appliedRate: Double = -1

    init?(item: LibraryReader.Item?, size: CGSize, scale: CGFloat) {
        guard let cls = NSClassFromString("CAContext") as? NSObject.Type,
              let ctx = cls.perform(NSSelectorFromString("remoteContextWithOptions:"), with: NSDictionary())?
                  .takeUnretainedValue() as? NSObject
        else {
            ExtLog.write("CAContext unavailable")
            return nil
        }
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        guard let tb else { return nil }
        timebase = tb
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 0)

        context = ctx
        self.item = item
        self.size = size
        self.scale = scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        displayLayer.frame = root.bounds
        displayLayer.contentsScale = scale
        displayLayer.videoGravity = ExtensionSettings.current.videoGravity
        displayLayer.controlTimebase = tb
        root.addSublayer(displayLayer)
        context.setValue(root, forKey: "layer")
        CATransaction.commit()

        contextID = (context.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0

        if let item {
            feeder = SampleFeeder(url: LibraryReader.fileURL(item), layer: displayLayer)
            feeder?.start()
            ExtLog.write("playing \(item.fileName) size=\(size) scale=\(scale) ctx=\(contextID)")
        } else {
            feeder = nil
            ExtLog.write("no video in library")
        }
        applyPlaybackState()
    }

    func update(size: CGSize?, scale: CGFloat?, presentationMode: String?, active: Bool?) {
        if let presentationMode { self.presentationMode = presentationMode }
        if let active { isActive = active }
        if let size, let scale {
            self.size = size
            self.scale = scale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = CGRect(origin: .zero, size: size)
            root.contentsScale = scale
            displayLayer.frame = root.bounds
            displayLayer.contentsScale = scale
            CATransaction.commit()
        }
        applyPlaybackState()
    }

    /// Re-evaluates settings + power state; called on every update and periodically.
    func applyPlaybackState() {
        let s = ExtensionSettings.current
        if displayLayer.videoGravity != s.videoGravity {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            displayLayer.videoGravity = s.videoGravity
            CATransaction.commit()
        }
        let rate = s.shouldAnimate(presentationMode: presentationMode, isActive: isActive) ? s.playbackSpeed : 0
        guard rate != appliedRate else { return }
        appliedRate = rate
        CMTimebaseSetRate(timebase, rate: rate)
        ExtLog.write("rate=\(rate) mode=\(presentationMode) active=\(isActive)")
    }

    func invalidate() {
        CMTimebaseSetRate(timebase, rate: 0)
        feeder?.stop()
        root.removeFromSuperlayer()
        context.perform(NSSelectorFromString("invalidate"))
    }

    /// Still image of the wallpaper (used by the agent for previews, menu bar tinting, etc.).
    func makeSnapshot() -> IOSurface? {
        let pixelW = max(1, Int(size.width * scale)), pixelH = max(1, Int(size.height * scale))
        guard let surface = IOSurface(properties: [
            .width: pixelW, .height: pixelH, .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surface.baseAddress, width: pixelW, height: pixelH, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return surface }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        if let item, let image = Self.stillImage(item) {
            let fit = ExtensionSettings.current.scaling == "fit"
            let ratioW = CGFloat(pixelW) / CGFloat(image.width), ratioH = CGFloat(pixelH) / CGFloat(image.height)
            let k = fit ? min(ratioW, ratioH) : max(ratioW, ratioH)
            let w = CGFloat(image.width) * k, h = CGFloat(image.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (CGFloat(pixelW) - w) / 2, y: (CGFloat(pixelH) - h) / 2, width: w, height: h))
        }
        return surface
    }

    static func stillImage(_ item: LibraryReader.Item) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(LibraryReader.thumbURL(item) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Reads compressed samples in a loop and enqueues them with continuously increasing
/// timestamps so the display layer plays the clip seamlessly forever.
final class SampleFeeder: @unchecked Sendable {
    private let asset: AVURLAsset
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "local.dolbobob.wallpap.feeder", qos: .userInitiated)
    private var track: AVAssetTrack?
    private var duration: CMTime = .zero
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var offset: CMTime = .zero
    private var lastEnd: CMTime = .zero
    private var stopped = false

    init(url: URL, layer: AVSampleBufferDisplayLayer) {
        asset = AVURLAsset(url: url)
        renderer = layer.sampleBufferRenderer
    }

    func start() {
        Task {
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    ExtLog.write("no video track"); return
                }
                let duration = try await asset.load(.duration)
                queue.async {
                    self.track = track
                    self.duration = duration
                    guard self.openReader() else { return }
                    self.renderer.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.feed() }
                }
            } catch {
                ExtLog.write("asset load failed: \(error)")
            }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.renderer.stopRequestingMediaData()
            self.reader?.cancelReading()
        }
    }

    private func openReader() -> Bool {
        guard let track, let reader = try? AVAssetReader(asset: asset) else { return false }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return false }
        reader.add(out)
        guard reader.startReading() else {
            ExtLog.write("reader failed: \(String(describing: reader.error))")
            return false
        }
        self.reader = reader
        output = out
        return true
    }

    private func feed() {
        if renderer.status == .failed {
            ExtLog.write("renderer failed: \(String(describing: renderer.error)) — flushing")
            renderer.flush()
        }
        while !stopped, renderer.isReadyForMoreMediaData {
            guard let out = output else { return }
            if let sample = out.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                if let retimed = retime(sample) { renderer.enqueue(retimed) }
            } else {
                // End of clip: continue right after the last frame.
                offset = CMTimeCompare(lastEnd, .zero) > 0 ? lastEnd : CMTimeAdd(offset, duration)
                reader?.cancelReading()
                guard openReader() else { return }
            }
        }
    }

    private func retime(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
                let end = CMTimeAdd(timing[i].presentationTimeStamp,
                                    timing[i].duration.isValid ? timing[i].duration : CMTime(value: 1, timescale: 30))
                if CMTimeCompare(end, lastEnd) > 0 { lastEnd = end }
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy
    }
}
