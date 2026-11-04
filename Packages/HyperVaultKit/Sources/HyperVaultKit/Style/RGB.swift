import Foundation

/// An opaque sRGB colour and the WCAG 2.x arithmetic the StyleKit's accessibility floors are made of. The formulas are
/// the ones the server's builder (lib/stylekit.ts) and the app's `DesignContrastTests` use, so a number computed here
/// is the number they compute.
public struct RGB: Sendable, Hashable, Codable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xff), green: UInt8((hex >> 8) & 0xff), blue: UInt8(hex & 0xff))
    }

    /// Exactly `#rrggbb`, a hash and six hex digits in either case, and nothing else. A colour with an alpha channel
    /// (`#rrggbbaa`, whatever the alpha, `ff` included), the `#rgb` shorthand, `rgb()`/`rgba()`, a name, a missing hash,
    /// a sign or surrounding space is nil. The wire format is opaque `#rrggbb`: flattening a translucent CSS colour over
    /// the page is the server's job, and a colour the app cannot read is a reason to keep the default look, not to guess.
    public init?(parsing text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return nil }
        var value: UInt32 = 0
        for byte in bytes[1...] {
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = value << 4 | digit
        }
        self.init(hex: value)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = RGB(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an opaque #rrggbb colour: \(text)"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    public var hex: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }

    /// `#rrggbb`, lower case: the wire spelling.
    public var hexString: String {
        let digits = String(hex, radix: 16)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }

    public static let white = RGB(hex: 0xFFFFFF)
    public static let black = RGB(hex: 0x000000)

    // MARK: WCAG 2.x

    /// Relative luminance, 0 (black) to 1 (white).
    public var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The contrast ratio, 1 to 21, whichever colour is lighter.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour at `alpha` over `surface`, each channel rounded: what a tag's fill looks like on the paper it sits on
    /// (the same rounding as `DesignContrastTests.composite`).
    public func composited(over surface: RGB, alpha: Double) -> RGB {
        func channel(_ top: UInt8, _ under: UInt8) -> UInt8 {
            UInt8(min(255, max(0, (alpha * Double(top) + (1 - alpha) * Double(under)).rounded())))
        }
        return RGB(red: channel(red, surface.red), green: channel(green, surface.green), blue: channel(blue, surface.blue))
    }

    /// White or black, whichever reads better as a label on this colour. For a fill the kit carries no label for (a
    /// destructive button's red, a tag), so the label is chosen from the fill and not assumed.
    public var legibleLabel: RGB {
        RGB.white.contrast(with: self) >= RGB.black.contrast(with: self) ? .white : .black
    }
}

// MARK: HSL (for moving a lightness: hue and saturation stay)

extension RGB {
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let high = max(r, g, b), low = min(r, g, b), lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        if high == r { hue = (g - b) / delta + (g < b ? 6 : 0) } else if high == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
        hue *= 60
        return (hue, saturation, lightness)
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        func channel(_ n: Double) -> UInt8 {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            let value = lightness - a * max(-1, min(k - 3, min(9 - k, 1)))
            return UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(red: channel(0), green: channel(8), blue: channel(4))
    }
}
