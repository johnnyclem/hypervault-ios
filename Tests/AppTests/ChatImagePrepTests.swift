import HyperVaultKit
import UIKit
import XCTest
@testable import HyperVault

final class ChatImagePrepTests: XCTestCase {
    /// A noisy picture, so JPEG cannot squash it: a large photo is mostly texture.
    private func photo(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            for _ in 0..<4_000 {
                UIColor(hue: .random(in: 0...1), saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(
                    x: .random(in: 0..<CGFloat(width)), y: .random(in: 0..<CGFloat(height)),
                    width: .random(in: 4...120), height: .random(in: 4...120)
                ))
            }
        }
        return image.pngData() ?? Data()
    }

    func testABigPhotoComesOutAsASmallUprightJPEG() throws {
        let prepared = try XCTUnwrap(ChatImagePrep.prepare(photo(width: 3_000, height: 2_000), name: "Photo 1.jpg"))
        XCTAssertEqual(prepared.upload.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.upload.name, "Photo 1.jpg")
        XCTAssertLessThanOrEqual(prepared.upload.data.count, ChatImageUpload.maxBytes)
        let image = try XCTUnwrap(UIImage(data: prepared.upload.data))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1_600)
        // Still wider than tall: shrunk, not squared off.
        XCTAssertGreaterThan(image.size.width, image.size.height)
        let thumb = try XCTUnwrap(UIImage(data: prepared.thumbnail))
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height), 240)
    }

    func testBytesThatAreNotAnImageAreRefused() {
        XCTAssertNil(ChatImagePrep.prepare(Data("not a picture".utf8), name: "x.jpg"))
    }
}
