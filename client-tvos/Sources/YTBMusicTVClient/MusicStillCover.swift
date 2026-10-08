import Foundation
import CoreGraphics
import ImageIO

enum StillCoverSource: Int, Sendable {
    case musicThumbnail = 1
    case catalog = 2
}

// The decoded image is immutable and can be passed from background decoding to the UI.
struct ValidatedStillCover: @unchecked Sendable {
    let image: CGImage
    let source: StillCoverSource
    let url: URL
}

enum StillCoverValidation {
    static func isVideoThumbnail(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "i.ytimg.com" || host.hasSuffix(".ytimg.com")
            || url.path.contains("/vi/") || url.path.contains("/vi_webp/")
    }

    static func decode(_ data: Data, url: URL, source: StillCoverSource) -> ValidatedStillCover? {
        guard !isVideoThumbnail(url),
              let encoded = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) >= (source == .catalog ? 800 : 600),
              Double(max(width, height)) / Double(min(width, height)) <= 1.02,
              let image = CGImageSourceCreateThumbnailAtIndex(encoded, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        // Unverified Music thumbnails can contain a video padded to a square.
        // Catalog artwork may intentionally use black negative space; retain it.
        if source == .musicThumbnail && hasVideoLetterbox(image) { return nil }
        return ValidatedStillCover(image: image, source: source, url: url)
    }

    static func hasVideoLetterbox(_ image: CGImage) -> Bool {
        let size = 96
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return false }
        func blackRow(_ row: Int) -> Bool {
            var dark = 0
            for x in 0..<size {
                let index = (row * size + x) * 4
                if max(pixels[index], pixels[index + 1], pixels[index + 2]) < 14 { dark += 1 }
            }
            return dark >= size - 2
        }
        var top = 0, bottom = 0
        while top < size / 3 && blackRow(top) { top += 1 }
        while bottom < size / 3 && blackRow(size - bottom - 1) { bottom += 1 }
        return top >= 8 && bottom >= 8 && abs(top - bottom) <= 3
            && !blackRow(size / 2)
    }
}
