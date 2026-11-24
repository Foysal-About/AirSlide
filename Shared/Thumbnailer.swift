import Foundation
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum Thumbnailer {
    /// Small JPEG preview (typically 15-40 KB) that travels with a drag or offer.
    static func jpeg(for url: URL, side: CGFloat = 200) async -> Data? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                               scale: 2, representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return flattenedJPEG(rep.cgImage)
    }

    static func flattenedJPEG(_ img: CGImage) -> Data? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func kind(of url: URL) -> String {
        let t = UTType(filenameExtension: url.pathExtension)
        if t?.conforms(to: .image) == true { return "image" }
        if t?.conforms(to: .movie) == true { return "video" }
        return "doc"
    }
}
