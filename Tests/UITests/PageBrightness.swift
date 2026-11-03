import UIKit
import XCTest

extension HyperVaultUITestCase {
    /// How bright the page is right now, 0 (black) to 1 (white). The probe the layout sweeps use, for a journey that changes
    /// the look and must see the page change with it.
    func currentPageBrightness() -> Double? {
        edgeBrightness(of: XCUIScreen.main.screenshot())
    }

    /// How bright the page is in a screenshot, 0 (black) to 1 (white): the middle one of 64 samples taken down a strip 12
    /// points in from the left edge, which is the page's own background on every screen (rows and cards start 16 points in)
    /// and, on a sheet, the sheet's. The middle one, not the average: a sheet over a web page has the page, dimmed but white,
    /// above it.
    func edgeBrightness(of screenshot: XCUIScreenshot) -> Double? {
        guard let image = screenshot.image.cgImage else { return nil }
        let scale = Int(screenshot.image.scale)
        let strip = CGRect(x: 12 * scale, y: image.height / 8, width: 4 * scale, height: image.height * 6 / 8)
        guard let edge = image.cropping(to: strip) else { return nil }
        let samples = 64
        var pixels = [UInt8](repeating: 0, count: samples * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: samples, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(edge, in: CGRect(x: 0, y: 0, width: 1, height: samples))
            return true
        }
        guard drawn else { return nil }
        let brightness = (0..<samples).map { row -> Double in
            let red = Double(pixels[row * 4]), green = Double(pixels[row * 4 + 1]), blue = Double(pixels[row * 4 + 2])
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
        return brightness.sorted()[samples / 2]
    }
}
