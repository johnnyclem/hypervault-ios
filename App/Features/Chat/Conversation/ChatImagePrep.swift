import HyperVaultKit
import ImageIO
import UIKit

/// A picture waiting in the composer, already small enough to send.
struct ChatPendingImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let upload: ChatImageUpload
    /// A small JPEG for the composer and the bubble.
    let thumbnail: Data
}

/// Makes a photo fit what `POST /api/chat` takes: a JPEG under `ChatImageUpload.maxBytes`, at most 1600 points
/// on its longest side. A camera photo is several megabytes and the server's request cap is near 4.5 MB for all
/// of a message, so this runs before anything is sent. HEIC, PNG, WebP and GIF all come out as JPEG, upright
/// (the camera's rotation is applied), with transparency flattened onto white.
enum ChatImagePrep {
    /// Sizes and qualities tried in turn until one fits.
    private static let sides: [CGFloat] = [1600, 1280, 1024, 800]
    private static let qualities: [CGFloat] = [0.8, 0.6, 0.45]
    private static let thumbnailSide: CGFloat = 240

    nonisolated static func prepare(_ data: Data, name: String) -> ChatPendingImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for side in sides {
            guard let image = flattened(source, maxPixel: side) else { return nil }
            for quality in qualities {
                guard let jpeg = image.jpegData(compressionQuality: quality) else { continue }
                if jpeg.count <= ChatImageUpload.maxBytes {
                    guard let thumb = flattened(source, maxPixel: thumbnailSide)?.jpegData(compressionQuality: 0.7) else {
                        return nil
                    }
                    return ChatPendingImage(
                        upload: ChatImageUpload(mimeType: "image/jpeg", data: jpeg, name: name), thumbnail: thumb
                    )
                }
            }
        }
        return nil
    }

    /// The first frame, scaled so its longest side is at most `maxPixel`, upright, drawn opaque.
    private nonisolated static func flattened(_ source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
