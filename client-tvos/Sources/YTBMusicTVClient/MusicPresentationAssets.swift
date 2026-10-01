import AVKit
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import UIKit

@MainActor
final class MusicPresentationAssets: ObservableObject {
    @Published var lyrics = MusicLyrics()
    @Published var lyricsLoading = false
    @Published var artworkImage: UIImage?
    @Published var motionURL: URL?
    @Published var backgroundVeil = 0.34
    @Published var colors: [Color] = [.indigo, .purple, .black]
    var accentColor: Color {
        let base = UIColor(colors.first ?? .indigo)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return .white }
        return Color(uiColor: UIColor(hue: hue, saturation: min(saturation, 0.75), brightness: max(brightness, 0.85), alpha: 1))
    }
    private var lyricsCache: [String: MusicLyrics] = [:]
    private var artworkCache: [String: MusicArtworkResult] = [:]
    private var generation = UUID()

    func load(_ media: MediaItem?, animated: Bool) async {
        let token = UUID(); generation = token
        lyrics = MusicLyrics(); motionURL = nil; artworkImage = nil
        colors = [.indigo, .purple, .black]
        backgroundVeil = 0.34
        guard let media else { lyricsLoading = false; return }
        lyricsLoading = true
        async let loadedLyrics: Void = loadLyrics(media, token: token)
        async let loadedArtwork: Void = loadArtwork(media, animated: animated, token: token)
        _ = await (loadedLyrics, loadedArtwork)
    }

    private func loadLyrics(_ media: MediaItem, token: UUID) async {
        if let cached = lyricsCache[media.id], cached.wordSynchronized {
            guard generation == token else { return }
            lyrics = cached; lyricsLoading = false
            return
        }
        // Display line lyrics as soon as they arrive, then upgrade to real word
        // timestamps without keeping the pane blocked by a slower provider.
        async let rich = MusicLookup.lyricsPlus(for: media)
        let base: MusicLyrics
        if let cached = lyricsCache[media.id] { base = cached }
        else { base = await MusicLookup.lrclibLyrics(for: media) }
        guard !Task.isCancelled, generation == token else { return }
        lyrics = base; lyricsLoading = false
        let words = await rich
        guard !Task.isCancelled, generation == token else { return }
        let result = words.wordSynchronized || (!base.synchronized && !words.lines.isEmpty) ? words : base
        if lyricsCache.count > 50 { lyricsCache.removeAll() }
        lyricsCache[media.id] = result
        lyrics = result
    }

    private func loadArtwork(_ media: MediaItem, animated: Bool, token: UUID) async {
        // Show the regular cover immediately; motion lookup never blocks music.
        await loadImage(media.artworkUrl, token: token)
        guard animated, !Task.isCancelled, generation == token else { return }
        let result: MusicArtworkResult
        let cacheKey = MusicLookup.normalized(media.artist) + ":" + MusicLookup.albumKey(media.album ?? media.title)
        if let cached = artworkCache[cacheKey] { result = cached }
        else { result = await MusicLookup.artwork(for: media) }
        guard !Task.isCancelled, generation == token else { return }
        if artworkCache.count > 50 { artworkCache.removeAll() }
        // Do not pin a temporary provider outage as a permanent static-only answer.
        if result.motion != nil { artworkCache[cacheKey] = result }
        motionURL = result.motion
        if result.still != media.artworkUrl { await loadImage(result.still, token: token) }
    }

    private func loadImage(_ url: URL?, token: UUID) async {
        guard let url, let data = try? await MusicLookup.fetch(url), let image = UIImage(data: data),
              generation == token, !Task.isCancelled else { return }
        artworkImage = image
        colors = Self.palette(image)
        backgroundVeil = Self.balancedVeil(image)
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

struct MusicMotionArtwork: UIViewRepresentable {
    let url: URL
    let active: Bool

    final class ArtworkView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var displayObserver: NSKeyValueObservation?
        var url: URL?
        override init(frame: CGRect) {
            super.init(frame: frame)
            player.isMuted = true
            player.volume = 0
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            isUserInteractionEnabled = false
            playerLayer.isHidden = true
            displayObserver = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { self?.playerLayer.isHidden = !ready }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func update(url: URL, active: Bool) {
            if self.url != url {
                player.pause(); looper?.disableLooping(); player.removeAllItems()
                self.url = url
                playerLayer.isHidden = true
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
            if active { player.play() } else { player.pause() }
        }
        func stop() {
            displayObserver?.invalidate(); displayObserver = nil
            player.pause(); looper?.disableLooping(); looper = nil; player.removeAllItems()
        }
    }

    func makeUIView(context: Context) -> ArtworkView { ArtworkView(frame: .zero) }
    func updateUIView(_ view: ArtworkView, context: Context) { view.update(url: url, active: active) }
    static func dismantleUIView(_ view: ArtworkView, coordinator: ()) { view.stop() }
}

// A native analogue of Orchard's blurred-artwork warp, rather than palette blobs.
struct MusicWarpedArtwork: UIViewRepresentable {
    let image: UIImage
    let active: Bool

    final class WarpView: UIView {
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let renderBounds = CGRect(x: 0, y: 0, width: 480, height: 270)
        private var sourceImage: UIImage?
        private var blurred: CIImage?
        private var displayLink: CADisplayLink?
        private var phase = 0.0
        private var previousTime: CFTimeInterval?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.contentsGravity = .resize
            clipsToBounds = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(image: UIImage, active: Bool) {
            if sourceImage !== image {
                sourceImage = image
                prepare(image)
                render()
            }
            if active && displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFramesPerSecond = 30
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else if !active {
                stop()
            }
        }

        private func prepare(_ image: UIImage) {
            guard let cg = image.cgImage else { blurred = nil; return }
            let input = CIImage(cgImage: cg)
            // Orchard uses a 1.32 overscan and a heavily blurred source.
            let scale = max(renderBounds.width / input.extent.width, renderBounds.height / input.extent.height) * 1.32
            let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: (renderBounds.width - scaled.extent.width) / 2,
                y: (renderBounds.height - scaled.extent.height) / 2))
            let softened = centered.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.24])
                .cropped(to: renderBounds)
            // Bake the blur once per cover; only spatial distortion runs each frame.
            blurred = context.createCGImage(softened, from: renderBounds).map { CIImage(cgImage: $0).clampedToExtent() }
        }

        @objc private func tick(_ link: CADisplayLink) {
            if let previousTime { phase += min(0.1, link.timestamp - previousTime) * 0.28 * 1.38 }
            previousTime = link.timestamp
            render()
        }

        private func render() {
            guard let blurred else { return }
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
            guard let output = bump.outputImage,
                  let cg = context.createCGImage(output, from: renderBounds) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = cg
            CATransaction.commit()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            previousTime = nil
        }
    }

    func makeUIView(context: Context) -> WarpView { WarpView(frame: .zero) }
    func updateUIView(_ view: WarpView, context: Context) { view.update(image: image, active: active) }
    static func dismantleUIView(_ view: WarpView, coordinator: ()) { view.stop() }
}
