import AVKit
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import SwiftUI
import UIKit

@MainActor
final class MusicPresentationAssets: ObservableObject {
    @Published var lyrics = MusicLyrics()
    @Published var lyricsLoading = false
    @Published var artworkImage: UIImage?
    let backdrop = MusicArtworkBackdrop()
    @Published var motionURL: URL?
    @Published var backgroundVeil = 0.34
    @Published var colors: [Color] = [.black, .gray.opacity(0.15), .black]
    var accentColor: Color { Self.readableAccent(colors.first ?? .indigo) }

    private static func readableAccent(_ color: Color) -> Color {
        let base = UIColor(color)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return .white }
        return Color(uiColor: UIColor(hue: hue, saturation: min(saturation, 0.75), brightness: max(brightness, 0.85), alpha: 1))
    }
    private var lyricsCache: [String: MusicLyrics] = [:]
    private var artworkCache: [String: MusicArtworkResult] = [:]
    private var backdropState = MusicBackdropState()
    var artworkGeneration: UUID { backdropState.generation }
    private var generation: UUID { backdropState.generation }
    private var lastVeilTime = 0.0
    private var lastAccentTime = 0.0
    private let paletteContext = CIContext(options: [.cacheIntermediates: false])
    private var currentStillSource: StillCoverSource?
    private final class CachedCover: NSObject {
        let cover: ValidatedStillCover
        init(_ cover: ValidatedStillCover) { self.cover = cover }
    }
    private let stillCache: NSCache<NSString, CachedCover> = {
        let cache = NSCache<NSString, CachedCover>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 24
        return cache
    }()

    func load(_ media: MediaItem?, animated: Bool, albumCover: @escaping @MainActor @Sendable (MediaItem) async -> URL? = { _ in nil }) async {
        let token = backdropState.begin(); currentStillSource = nil; lastVeilTime = 0; lastAccentTime = 0
        lyrics = MusicLyrics(); motionURL = nil; artworkImage = nil
        // Keep the previous backdrop until a new cover arrives; clearing it
        // would expose a colored fallback during every song transition.
        guard let media else {
            lyricsLoading = false
            backdrop.frame = nil
            colors = [.black, .gray.opacity(0.15), .black]
            backgroundVeil = 0.34
            return
        }
        lyricsLoading = true
        async let loadedLyrics: Void = loadLyrics(media, token: token)
        async let loadedArtwork: Void = loadArtwork(media, animated: animated, token: token, albumCover: albumCover)
        _ = await (loadedLyrics, loadedArtwork)
    }

    private func loadLyrics(_ media: MediaItem, token: UUID) async {
        // Generic studio lyric timings cannot synchronize an unmatched live video.
        if media.type != "song", media.title.range(of: "\\blive\\b|\\bconcert\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            guard generation == token else { return }
            lyrics = MusicLyrics(); lyricsLoading = false
            return
        }
        let lyricsKey = media.videoId ?? media.id
        if let cached = lyricsCache[lyricsKey], cached.wordSynchronized {
            guard generation == token else { return }
            lyrics = cached; lyricsLoading = false
            return
        }
        let cached = lyricsCache[lyricsKey]
        if let cached { lyrics = cached; lyricsLoading = false }
        // Publish the first usable result; a slow base provider must not hold
        // back word timings already returned by a richer provider.
        await withTaskGroup(of: MusicLyrics.self) { group in
            group.addTask { await MusicLookup.lyricsPlus(for: media) }
            if cached == nil { group.addTask { await MusicLookup.lrclibLyrics(for: media) } }
            var best = cached ?? MusicLyrics()
            for await result in group {
                guard !Task.isCancelled, generation == token else { group.cancelAll(); return }
                if result.wordSynchronized || (result.synchronized && !best.synchronized) || (best.lines.isEmpty && (!result.lines.isEmpty || result.instrumental)) {
                    best = result
                    lyrics = best; lyricsLoading = false
                }
                if best.wordSynchronized { group.cancelAll(); break }
            }
            guard !Task.isCancelled, generation == token else { return }
            if lyricsCache.count > 50 { lyricsCache.removeAll() }
            if !best.lines.isEmpty || best.instrumental { lyricsCache[lyricsKey] = best }
            lyrics = best; lyricsLoading = false
        }
    }

    private func loadArtwork(_ media: MediaItem, animated: Bool, token: UUID, albumCover: @escaping @MainActor @Sendable (MediaItem) async -> URL?) async {
        guard animated else { await loadStillArtwork(media, token: token, albumCover: albumCover); return }
        // Fetch the still cover and animation independently; a slow thumbnail
        // must not postpone finding or starting the motion artwork.
        async let stillCover: Void = loadStillArtwork(media, token: token, albumCover: albumCover)
        guard !Task.isCancelled, generation == token else { return }
        let result: MusicArtworkResult
        let cacheKey = MusicLookup.normalized(media.artist) + ":" + MusicLookup.albumKey(media.album ?? media.title)
        if let cached = artworkCache[cacheKey] { result = cached }
        else { result = await MusicLookup.artwork(for: media) }
        guard !Task.isCancelled, generation == token else { return }
        if artworkCache.count > 50 { artworkCache.removeAll() }
        // Do not pin a temporary provider outage as a permanent static-only answer.
        if result.motion != nil { artworkCache[cacheKey] = result }
        motionURL = result.motion
        _ = await stillCover
        guard !Task.isCancelled, generation == token else { return }
        // These providers are for motion. Their static fields can be tiny previews
        // or video thumbnails, so they never replace the validated still cover.
    }

    private func loadStillArtwork(_ media: MediaItem, token: UUID, albumCover: @escaping @MainActor @Sendable (MediaItem) async -> URL?) async {
        let cacheKey = MusicLookup.normalized(media.artist) + ":" + MusicLookup.albumKey(media.album ?? "")
            + ":" + MusicLookup.normalized(MusicLookup.songTitle(media.title, artist: media.artist))
        if let cached = stillCache.object(forKey: cacheKey as NSString) {
            publishStill(cached.cover, token: token)
            if cached.cover.source == .catalog { return }
        }
        // Start metadata lookup now; a failing thumbnail must not delay it.
        async let thumbnail: Bool = loadImage(media.artworkUrl, source: .musicThumbnail, token: token)
        async let nativeAlbum: Void = loadAlbumArtwork(media, token: token, cacheKey: cacheKey, albumCover: albumCover)
        _ = await MusicLookup.catalogStill(for: media) { [weak self] url in
            guard let self else { return false }
            return await self.loadImage(url, source: .catalog, token: token, cacheKey: cacheKey)
        }
        _ = await (thumbnail, nativeAlbum)
    }

    private func loadAlbumArtwork(_ media: MediaItem, token: UUID, cacheKey: String,
        albumCover: @escaping @MainActor @Sendable (MediaItem) async -> URL?) async {
        // Give the cheap/current cover and catalog a head start. Only ask the
        // server for the album header when the player still has no usable image.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard generation == token, !Task.isCancelled, artworkImage == nil else { return }
        guard let url = await albumCover(media), generation == token, !Task.isCancelled else { return }
        await loadImage(url, source: .album, token: token, cacheKey: cacheKey)
    }

    @discardableResult
    private func loadImage(_ url: URL?, source: StillCoverSource, token: UUID, cacheKey: String? = nil) async -> Bool {
        guard let url, source == .album || !StillCoverValidation.isVideoThumbnail(url) else { return false }
        let large = MusicLookup.highResolutionStillURL(url)
        let candidates = large == url ? [url] : [large, url]
        for candidate in candidates {
            guard generation == token, !Task.isCancelled else { return false }
            guard let data = try? await MusicLookup.fetch(candidate, timeout: 10) else { continue }
            // Decode, inspect and downsample away from the player/UI actor.
            let cover = await Task.detached(priority: .utility) {
                StillCoverValidation.decode(data, url: candidate, source: source)
            }.value
            guard generation == token, !Task.isCancelled else { return false }
            guard let cover else {
                print("Rejected still cover from \(candidate.host ?? "unknown"): invalid size, shape or video bars")
                continue
            }
            let published = publishStill(cover, token: token)
            if published, let cacheKey, source != .musicThumbnail {
                stillCache.setObject(CachedCover(cover), forKey: cacheKey as NSString,
                    cost: cover.image.bytesPerRow * cover.image.height)
            }
            return true
        }
        return false
    }

    @discardableResult
    private func publishStill(_ cover: ValidatedStillCover, token: UUID) -> Bool {
        guard generation == token else { return false }
        if let currentStillSource, currentStillSource.rawValue > cover.source.rawValue { return false }
        if currentStillSource == cover.source, let current = artworkImage?.cgImage,
           current.width * current.height > cover.image.width * cover.image.height { return false }
        currentStillSource = cover.source
        let image = UIImage(cgImage: cover.image)
        artworkImage = image
        if backdropState.acceptsStill(token) {
            backdrop.frame = MusicBackdropFrame(image: CIImage(cgImage: cover.image), sourceID: token, live: false)
            colors = Self.palette(image)
            backgroundVeil = Self.balancedVeil(image)
        }
        return true
    }

    func receiveMotionFrame(_ image: CIImage, url: URL, token: UUID) {
        guard motionURL == url, backdropState.acceptLive(token) else { return }
        backdrop.frame = MusicBackdropFrame(image: image, sourceID: token, live: true)
        // Follow major brightness changes slowly, without making the veil pulse.
        let now = CACurrentMediaTime()
        // Only palette/contrast analysis needs CPU pixels. Keep video frames
        // on the GPU, and make this small copy below three times per second.
        guard now - lastAccentTime >= 0.4 else { return }
        guard let cg = paletteContext.createCGImage(image, from: image.extent) else { return }
        let sample = UIImage(cgImage: cg)
        updateMotionAccent(sample, at: now)
        if now - lastVeilTime >= 0.5 {
            lastVeilTime = now
            let target = Self.balancedVeil(sample)
            if abs(target - backgroundVeil) >= 0.005 {
                backgroundVeil += min(0.03, max(-0.03, target - backgroundVeil))
            }
        }
    }

    private func updateMotionAccent(_ image: UIImage, at time: CFTimeInterval) {
        // Reuse the displayed video's samples, but keep palette work and UI
        // changes below three per second. Color fades do not alter focus timing.
        guard time - lastAccentTime >= 0.4 else { return }
        lastAccentTime = time
        let sampled = Self.palette(image)
        guard let first = sampled.first else { return }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(first).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A brief black frame/loop seam has no meaningful new accent. Retain
        // the last color instead of flashing white during the video's fade.
        guard saturation >= 0.08 || brightness > 0.23 else { return }
        var oldR: CGFloat = 0, oldG: CGFloat = 0, oldB: CGFloat = 0
        var newR: CGFloat = 0, newG: CGFloat = 0, newB: CGFloat = 0
        UIColor(accentColor).getRed(&oldR, green: &oldG, blue: &oldB, alpha: &alpha)
        UIColor(Self.readableAccent(first)).getRed(&newR, green: &newG, blue: &newB, alpha: &alpha)
        let dr = newR - oldR, dg = newG - oldG, db = newB - oldB
        guard dr * dr + dg * dg + db * db > 0.0009 else { return }
        // All existing controls, the progress fill and lyric glow share this
        // Artwork accent, so they continue to match each other as it changes.
        withAnimation(.easeInOut(duration: 0.6)) { colors = sampled }
    }

    static func balancedVeil(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0.34 }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rgb = pixel.prefix(3).map { Double($0) / 255 }
        let tint = [0.024, 0.04, 0.028], veil = [3.0 / 255, 7.0 / 255, 4.0 / 255]
        func luminance(_ channels: [Double]) -> Double {
            let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        for step in 0...48 {
            let alpha = 0.34 + Double(step) * 0.01
            let backdrop = (0..<3).map { index in
                let tinted = rgb[index] * 0.58 + tint[index] * 0.42
                return (tinted * (1 - alpha) + veil[index] * alpha) * 0.82 + tint[index] * 0.18
            }
            let light = luminance(backdrop)
            if 1.05 / (light + 0.05) >= 4.5 && (luminance([0.65, 0.65, 0.65]) + 0.05) / (light + 0.05) >= 3 { return alpha }
        }
        return 0.82
    }

    static func palette(_ image: UIImage) -> [Color] {
        let dimension = 48
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
        guard let cg = image.cgImage else { return [.indigo, .purple, .black] }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(dimension), height: CGFloat(dimension)))
            return true
        }
        guard rendered else { return [.indigo, .purple, .black] }
        var buckets: [Int: (r: Double, g: Double, b: Double, count: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] > 220 else { continue }
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let key = (r / 32) * 64 + (g / 32) * 8 + b / 32
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.r + Double(r), old.g + Double(g), old.b + Double(b), old.count + 1)
        }
        // Weight both coverage and chroma: large black/gray areas should not
        // bury a cover's meaningful colors, but tiny isolated pixels are noise.
        let minimumCount = max(3, dimension * dimension / 200)
        func score(_ bucket: (r: Double, g: Double, b: Double, count: Int)) -> Double {
            let maximum = max(bucket.r, bucket.g, bucket.b) / Double(bucket.count)
            let minimum = min(bucket.r, bucket.g, bucket.b) / Double(bucket.count)
            let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
            return sqrt(Double(bucket.count)) * (0.2 + saturation) * (0.35 + 0.65 * maximum / 255)
        }
        let substantial = buckets.values.filter { $0.count >= minimumCount }
        let ranked = (substantial.isEmpty ? Array(buckets.values) : substantial).sorted { score($0) > score($1) }
        var selected: [(r: Double, g: Double, b: Double, count: Int)] = []
        for bucket in ranked {
            let unique = selected.allSatisfy { existing in
                let dr = bucket.r / Double(bucket.count) - existing.r / Double(existing.count)
                let dg = bucket.g / Double(bucket.count) - existing.g / Double(existing.count)
                let db = bucket.b / Double(bucket.count) - existing.b / Double(existing.count)
                return dr * dr + dg * dg + db * db > 3600
            }
            if unique { selected.append(bucket) }
            if selected.count == 3 { break }
        }
        let sorted = selected
        let result = sorted.map { bucket in
            let sampled = UIColor(red: CGFloat(bucket.r / Double(bucket.count) / 255),
                                  green: CGFloat(bucket.g / Double(bucket.count) / 255),
                                  blue: CGFloat(bucket.b / Double(bucket.count) / 255), alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            sampled.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            // Keep the sampled hue, lift dim color, and modestly enrich chroma.
            // Neutral artwork remains neutral instead of acquiring a fallback hue.
            let vividSaturation = saturation < 0.08 ? saturation : min(0.88, saturation * 1.12)
            let vividBrightness = saturation < 0.08 ? min(0.68, max(0.22, brightness)) : min(0.82, max(0.5, brightness * 1.12))
            return Color(uiColor: UIColor(hue: hue, saturation: vividSaturation, brightness: vividBrightness, alpha: 1))
        }
        return result.isEmpty ? [.indigo, .purple, .black] : result
    }
}

struct MusicBackdropFrame {
    let image: CIImage
    let sourceID: UUID
    let live: Bool
}

// Only the background subscribes to video frames; controls and lyrics do not
// need a SwiftUI update for every frame of the cover animation.
@MainActor
final class MusicArtworkBackdrop: ObservableObject {
    @Published var frame: MusicBackdropFrame?
}

struct MusicMotionArtwork: UIViewRepresentable {
    let url: URL
    let active: Bool
    let onFrame: @MainActor (CIImage) -> Void

    final class ArtworkView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var displayObserver: NSKeyValueObservation?
        var url: URL?
        var onFrame: (@MainActor (CIImage) -> Void)?
        private var displayLink: CADisplayLink?
        private var outputItem: AVPlayerItem?
        private var output: AVPlayerItemVideoOutput?
        override init(frame: CGRect) {
            super.init(frame: frame)
            player.isMuted = true
            player.volume = 0
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = UIColor.black.cgColor
            isUserInteractionEnabled = false
            playerLayer.isHidden = true
            displayObserver = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { self?.playerLayer.isHidden = !ready }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func update(url: URL, active: Bool, onFrame: @escaping @MainActor (CIImage) -> Void) {
            self.onFrame = onFrame
            if self.url != url {
                stopSampling(); detachOutput()
                player.pause(); looper?.disableLooping(); player.removeAllItems()
                self.url = url
                playerLayer.isHidden = true
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 1
                looper = AVPlayerLooper(player: player, templateItem: item)
                for loopItem in player.items() { loopItem.preferredForwardBufferDuration = 1 }
            }
            if active {
                player.playImmediately(atRate: 1)
                if displayLink == nil {
                    let link = CADisplayLink(target: self, selector: #selector(sampleFrame(_:)))
                    link.preferredFramesPerSecond = 30
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                }
            } else { player.pause(); stopSampling() }
        }

        @objc private func sampleFrame(_ link: CADisplayLink) {
            // AVPlayerLooper creates replica items. Attach to the item actually
            // on screen, and reattach at each loop, not to the template item.
            if outputItem !== player.currentItem {
                detachOutput()
                if let item = player.currentItem {
                    let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ])
                    videoOutput.suppressesPlayerRendering = false
                    item.add(videoOutput)
                    outputItem = item; output = videoOutput
                }
            }
            guard playerLayer.isReadyForDisplay, let output else { return }
            let time = output.itemTime(forHostTime: link.targetTimestamp)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
            autoreleasepool {
                let input = CIImage(cvPixelBuffer: buffer)
                guard input.extent.width > 0, input.extent.height > 0 else { return }
                let scale = min(1, 480 / max(input.extent.width, input.extent.height))
                let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                // CIImage retains the decoded buffer; no per-frame CGImage
                // conversion or CPU readback is needed for the background.
                onFrame?(small)
            }
        }

        private func stopSampling() {
            displayLink?.invalidate(); displayLink = nil
        }

        private func detachOutput() {
            if let output, let outputItem { outputItem.remove(output) }
            output = nil; outputItem = nil
        }
        func stop() {
            stopSampling(); detachOutput(); onFrame = nil
            displayObserver?.invalidate(); displayObserver = nil
            player.pause(); looper?.disableLooping(); looper = nil; player.removeAllItems()
        }
    }

    func makeUIView(context: Context) -> ArtworkView { ArtworkView(frame: .zero) }
    func updateUIView(_ view: ArtworkView, context: Context) { view.update(url: url, active: active, onFrame: onFrame) }
    static func dismantleUIView(_ view: ArtworkView, coordinator: ()) { view.stop() }
}

// A native analogue of Orchard's blurred-artwork warp, rather than palette blobs.
struct MusicWarpedArtwork: UIViewRepresentable {
    let frame: MusicBackdropFrame
    let active: Bool

    final class WarpView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
        private let context: CIContext
        private let commandQueue: MTLCommandQueue?
        private let frameSlots = DispatchSemaphore(value: 2)
        private let renderColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        private let renderBounds = CGRect(x: 0, y: 0, width: 480, height: 270)
        private var sourceImage: CIImage?
        private var pendingFrame: MusicBackdropFrame?
        private var sourceID: UUID?
        private var liveSource = false
        private var transitionDuration = 1.2
        private var blurred: CIImage?
        private var transitionFrom: CIImage?
        private var transitionStart: CFTimeInterval?
        private var displayLink: CADisplayLink?
        private var clock = MusicBackdropClock()

        override init(frame: CGRect) {
            let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
            commandQueue = queue
            if let queue {
                context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
            } else {
                context = CIContext(options: [.cacheIntermediates: false])
            }
            super.init(frame: frame)
            isUserInteractionEnabled = false
            clipsToBounds = true
            metalLayer.device = queue?.device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            metalLayer.drawableSize = renderBounds.size
            metalLayer.colorspace = renderColorSpace
            metalLayer.isOpaque = true
            metalLayer.allowsNextDrawableTimeout = true
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Initial paused/static artwork also gets a drawable after layout.
            if displayLink == nil { render() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { render() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(frame: MusicBackdropFrame, active: Bool) {
            if sourceImage !== frame.image { pendingFrame = frame }
            if active && displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFramesPerSecond = 60
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else if !active {
                stop()
                render()
            }
        }

        private func applyPendingFrame(at time: CFTimeInterval, commandBuffer: MTLCommandBuffer) {
            guard let frame = pendingFrame, let next = prepare(frame.image, commandBuffer: commandBuffer) else { return }
            let sameLiveSource = frame.live && liveSource && sourceID == frame.sourceID
            let enteringVideo = sameLiveSource && transitionDuration > 0.2
                && transitionStart.map { time - $0 < transitionDuration } == true
            if !enteringVideo {
                // Bound the blend history in a small GPU texture rather than
                // building a growing filter graph or reading pixels to the CPU.
                transitionFrom = blendedSource(at: time).flatMap { bake($0, commandBuffer: commandBuffer) }
                transitionStart = transitionFrom == nil ? nil : time
                transitionDuration = sameLiveSource ? 0.06 : (frame.live ? 1.8 : 1.2)
            }
            sourceImage = frame.image; sourceID = frame.sourceID; liveSource = frame.live
            blurred = next
            pendingFrame = nil
        }

        private func prepare(_ input: CIImage, commandBuffer: MTLCommandBuffer) -> CIImage? {
            guard input.extent.width > 0, input.extent.height > 0 else { return nil }
            // Preserve the accepted blur, saturation, overscan and warp strength.
            let scale = max(renderBounds.width / input.extent.width, renderBounds.height / input.extent.height) * 1.32
            let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (renderBounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (renderBounds.height - scaled.extent.height) / 2 - scaled.extent.minY))
            let softened = centered.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.24])
                .cropped(to: renderBounds)
            return bake(softened, commandBuffer: commandBuffer)
        }

        private func bake(_ input: CIImage, commandBuffer: MTLCommandBuffer) -> CIImage? {
            guard let device = commandQueue?.device else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(renderBounds.width), height: Int(renderBounds.height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            context.render(input, to: texture, commandBuffer: commandBuffer, bounds: renderBounds, colorSpace: renderColorSpace)
            return CIImage(mtlTexture: texture, options: [.colorSpace: renderColorSpace])?.clampedToExtent()
        }

        @objc private func tick(_ link: CADisplayLink) {
            clock.advance(to: link.targetTimestamp)
            autoreleasepool { render(at: link.targetTimestamp) }
        }

        private func blendedSource(at time: CFTimeInterval) -> CIImage? {
            guard let blurred else { return nil }
            guard let previous = transitionFrom, let start = transitionStart else { return blurred }
            let progress = min(1, max(0, (time - start) / transitionDuration))
            if progress >= 1 {
                transitionFrom = nil; transitionStart = nil
                return blurred
            }
            let blend = CIFilter.dissolveTransition()
            blend.inputImage = previous
            blend.targetImage = blurred
            blend.time = Float(progress * progress * (3 - 2 * progress))
            return blend.outputImage ?? blurred
        }

        private func render(at time: CFTimeInterval = CACurrentMediaTime()) {
            guard window != nil, bounds.width > 0, bounds.height > 0, let commandQueue,
                  frameSlots.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer { if !submitted { frameSlots.signal() } }
            guard let drawable = metalLayer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            // Coalesce source updates here: only the newest video frame is
            // prepared, and slow GPU work never queues an unlimited backlog.
            applyPendingFrame(at: time, commandBuffer: commandBuffer)
            guard let blurred = blendedSource(at: time) else { return }
            let phase = clock.phase
            let width = renderBounds.width, height = renderBounds.height
            let twirl = CIFilter.twirlDistortion()
            twirl.inputImage = blurred
            twirl.center = CGPoint(x: width * (0.5 + 0.3 * sin(phase * 0.79)),
                                   y: height * (0.5 + 0.32 * cos(phase * 0.91)))
            twirl.radius = Float(width * 0.82)
            twirl.angle = Float(sin(phase * 0.87) * 1.6 * 0.92)
            let bump = CIFilter.bumpDistortion()
            bump.inputImage = twirl.outputImage
            bump.center = CGPoint(x: width * (0.5 + 0.34 * cos(phase * 1.11)),
                                  y: height * (0.5 + 0.34 * sin(phase * 0.73)))
            bump.radius = Float(width * 0.7)
            bump.scale = Float(sin(phase * 0.97) * 0.65 * 0.92)
            guard let output = bump.outputImage else { return }
            context.render(output, to: drawable.texture, commandBuffer: commandBuffer,
                bounds: renderBounds, colorSpace: renderColorSpace)
            commandBuffer.present(drawable, atTime: time)
            let slots = frameSlots
            commandBuffer.addCompletedHandler { _ in slots.signal() }
            submitted = true
            commandBuffer.commit()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            clock.pause()
        }
    }

    func makeUIView(context: Context) -> WarpView { WarpView(frame: .zero) }
    func updateUIView(_ view: WarpView, context: Context) { view.update(frame: frame, active: active) }
    static func dismantleUIView(_ view: WarpView, coordinator: ()) { view.stop() }
}
