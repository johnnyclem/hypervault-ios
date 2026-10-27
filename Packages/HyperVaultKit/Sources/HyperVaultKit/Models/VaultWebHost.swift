import Foundation

// `webHost` of lib/secrets/items.ts relies on `new URL(url)` throwing for a bad address:
//
//     const { protocol, hostname } = new URL(url);
//     return (protocol === "http:" || protocol === "https:") && hostname ? hostname : null;
//
// This is that parser for an http(s) address, written out over Unicode scalars so that it gives one answer on every
// platform. `URL(string:)` cannot stand in for it: it is RFC 3986 and not WHATWG, its answer changes with the OS
// and the SDK it was linked against (since iOS 17 it percent-encodes what used to make it fail, so
// "https://exa mple.com" parses), and it refuses `"` and `{` in a host, which `new URL` takes.
//
// What is ported, from the WHATWG URL standard (https://url.spec.whatwg.org/) as Node 22 runs it:
//  - the input is stripped of leading and trailing C0 controls and spaces and of tabs and line breaks anywhere;
//  - the scheme is `http` or `https` in any case, followed by any number of "/" and "\" (also none, so
//    "http:example.com" is an address);
//  - the authority ends at the first "/", "\", "?" or "#"; user information ends at the last "@" and nothing after
//    that "@" is an error; the port is ASCII digits only, at most 65535, and may be empty;
//  - a host in [...] is an IPv6 address, validated and written the short way;
//  - any other host is percent-decoded, read as UTF-8, mapped (lower case; ignorable characters dropped), turned
//    into ASCII (punycode for a label with letters outside ASCII), refused when it holds a forbidden domain code
//    point, and read as an IPv4 address when its last label is a number ("0x7f.1" is 127.0.0.1, "1.2.3.4.5" and
//    "256.1.1.1" are errors).
//
// Not ported: the full IDNA (UTS 46) tables. Node maps compatibility characters (fullwidth forms, superscripts,
// ligatures), applies the bidi and joiner rules and refuses unassigned code points and many symbols. Here a letter
// outside ASCII is lower-cased and kept, and only the classes that matter in a pasted address are refused: the
// separators and controls that turn into or hold a space (U+00A0, U+3000, U+0085 ...), format characters other
// than the ignorable ones, private use, U+FFFD, and the fullwidth forms of ASCII are read as the ASCII they stand
// for (so a fullwidth "：" is the forbidden ":"). Where the two differ, this accepts what Node refuses (Save is
// enabled and the server answers 400, which the form shows) and never the reverse. Unassigned code points are
// accepted for the same reason: the Unicode tables differ between OS versions.

enum VaultWebHost {
    /// The host `new URL(address).hostname` gives for an http(s) address, or nil.
    static func host(of address: String) -> String? {
        var chars = address.unicodeScalars.map { $0.value }
        while let first = chars.first, first <= 0x20 { chars.removeFirst() }
        while let last = chars.last, last <= 0x20 { chars.removeLast() }
        chars.removeAll { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }

        // The scheme: a letter, then letters, digits, "+", "-" and ".", then ":".
        guard let firstChar = chars.first, isASCIILetter(firstChar) else { return nil }
        var index = 0
        var scheme: [UInt32] = []
        while index < chars.count, isSchemeCharacter(chars[index]) {
            scheme.append(lowercasedASCII(chars[index]))
            index += 1
        }
        guard index < chars.count, chars[index] == 0x3A else { return nil }
        let http: [UInt32] = [0x68, 0x74, 0x74, 0x70]
        let https: [UInt32] = [0x68, 0x74, 0x74, 0x70, 0x73]
        guard scheme == http || scheme == https else { return nil }
        index += 1
        while index < chars.count, chars[index] == 0x2F || chars[index] == 0x5C { index += 1 }

        // The authority, and the host and port in it.
        var end = index
        while end < chars.count, !isAuthorityEnd(chars[end]) { end += 1 }
        var authority = Array(chars[index..<end])
        if let at = authority.lastIndex(of: 0x40) {
            authority = Array(authority[(at + 1)...])
            if authority.isEmpty { return nil }
        }
        var insideBrackets = false
        var colon: Int?
        for (position, char) in authority.enumerated() {
            if char == 0x3A, !insideBrackets {
                colon = position
                break
            }
            if char == 0x5B { insideBrackets = true } else if char == 0x5D { insideBrackets = false }
        }
        let hostChars = colon.map { Array(authority[..<$0]) } ?? authority
        if hostChars.isEmpty { return nil }
        if let colon, !isValidPort(Array(authority[(colon + 1)...])) { return nil }
        return parseHost(hostChars)
    }

    // MARK: Port

    /// Empty, or ASCII digits with a value of at most 65535.
    private static func isValidPort(_ port: [UInt32]) -> Bool {
        guard port.allSatisfy(isASCIIDigit) else { return false }
        let significant = port.drop { $0 == 0x30 }
        guard significant.count <= 5 else { return false }
        var value = 0
        for digit in significant { value = value * 10 + Int(digit - 0x30) }
        return value <= 65535
    }

    // MARK: Host

    private static func parseHost(_ host: [UInt32]) -> String? {
        if host.first == 0x5B {
            guard host.count >= 2, host.last == 0x5D else { return nil }
            return parseIPv6(Array(host[1..<(host.count - 1)]))
        }
        let bytes = percentDecoded(Array(string(from: host).utf8))
        let domain = String(decoding: bytes, as: UTF8.self).unicodeScalars.map { $0.value }
        guard let ascii = domainToASCII(domain), !ascii.isEmpty else { return nil }
        if ascii.contains(where: isForbiddenDomainCharacter) { return nil }
        if endsInANumber(ascii) { return parseIPv4(ascii) }
        return string(from: ascii)
    }

    /// `%` and two hex digits become the byte; any other `%` stays.
    private static func percentDecoded(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var position = 0
        while position < bytes.count {
            if bytes[position] == 0x25, position + 2 < bytes.count,
               let high = hexValue(UInt32(bytes[position + 1])), let low = hexValue(UInt32(bytes[position + 2])) {
                out.append(UInt8(high * 16 + low))
                position += 3
            } else {
                out.append(bytes[position])
                position += 1
            }
        }
        return out
    }

    /// The forbidden domain code points: C0 controls and space, # % / : < > ? @ [ \ ] ^ | and DEL.
    private static func isForbiddenDomainCharacter(_ value: UInt32) -> Bool {
        switch value {
        case 0x00...0x20, 0x23, 0x25, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x5E, 0x7C, 0x7F:
            return true
        default:
            return false
        }
    }

    // MARK: Domain to ASCII

    private static let punycodePrefix: [UInt32] = [0x78, 0x6E, 0x2D, 0x2D]

    private static func domainToASCII(_ domain: [UInt32]) -> [UInt32]? {
        var mapped: [UInt32] = []
        for value in domain {
            if value < 0x80 {
                mapped.append(lowercasedASCII(value))
            } else if value >= 0xFF01, value <= 0xFF5E {
                mapped.append(lowercasedASCII(value - 0xFEE0))  // fullwidth forms stand for their ASCII twins
            } else if value == 0x3002 || value == 0xFF61 {
                mapped.append(0x2E)  // the ideographic and halfwidth ideographic full stops separate labels
            } else if isIgnored(value) {
                continue
            } else {
                guard let scalar = Unicode.Scalar(value), !isRefused(scalar) else { return nil }
                mapped.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars.map { $0.value })
            }
        }

        var out: [UInt32] = []
        for (position, label) in split(mapped, on: 0x2E).enumerated() {
            if position > 0 { out.append(0x2E) }
            let isASCII = label.allSatisfy { $0 < 0x80 }
            if isASCII, label.starts(with: punycodePrefix) {
                // An "xn--" label has to decode, to something that is a label as it stands.
                guard let decoded = decodePunycode(Array(label.dropFirst(4))), !decoded.isEmpty else { return nil }
                for value in decoded where value >= 0x80 {
                    guard let scalar = Unicode.Scalar(value), !isRefused(scalar), !isIgnored(value) else { return nil }
                    guard scalar.properties.lowercaseMapping.unicodeScalars.map({ $0.value }) == [value] else { return nil }
                }
                if let first = decoded.first, first >= 0x80, let scalar = Unicode.Scalar(first), isMark(scalar) { return nil }
                out.append(contentsOf: label)
            } else if isASCII {
                out.append(contentsOf: label)
            } else {
                if label.starts(with: punycodePrefix) { return nil }
                if let first = label.first, let scalar = Unicode.Scalar(first), isMark(scalar) { return nil }
                out.append(contentsOf: punycodePrefix)
                out.append(contentsOf: encodePunycode(label))
            }
        }
        return out
    }

    /// Characters IDNA maps to nothing: the soft hyphen, the combining grapheme joiner, Mongolian free variation
    /// selectors, zero width space, word joiner, invisible plus, variation selectors, the byte order mark and
    /// the shorthand format controls.
    private static func isIgnored(_ value: UInt32) -> Bool {
        switch value {
        case 0xAD, 0x34F, 0x180B...0x180D, 0x180F, 0x200B, 0x2060, 0x2064, 0xFE00...0xFE0F, 0xFEFF,
             0x1BCA0...0x1BCA3, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    /// A character outside ASCII that no host may hold: controls, every kind of space and separator, private use,
    /// format characters (the joiners and bidi controls among them) and U+FFFD, which is what bytes that are not
    /// UTF-8 decode to.
    private static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0xFFFD { return true }
        switch scalar.properties.generalCategory {
        case .control, .spaceSeparator, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .format:
            return true
        default:
            return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    // MARK: Punycode (RFC 3492)

    private static let punyBase = 36
    private static let punyTMin = 1
    private static let punyTMax = 26
    private static let punySkew = 38
    private static let punyDamp = 700
    private static let punyInitialBias = 72
    private static let punyInitialN = 128

    private static func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
        var delta = first ? delta / punyDamp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((punyBase - punyTMin) * punyTMax) / 2 {
            delta /= punyBase - punyTMin
            k += punyBase
        }
        return k + ((punyBase - punyTMin + 1) * delta) / (delta + punySkew)
    }

    private static func threshold(_ k: Int, _ bias: Int) -> Int {
        if k <= bias { return punyTMin }
        if k >= bias + punyTMax { return punyTMax }
        return k - bias
    }

    private static func punycodeDigit(_ value: Int) -> UInt32 {
        UInt32(value < 26 ? 0x61 + value : 0x30 + value - 26)
    }

    /// The part of an "xn--" label after the prefix.
    private static func encodePunycode(_ input: [UInt32]) -> [UInt32] {
        var out = input.filter { $0 < 0x80 }
        let basic = out.count
        var handled = basic
        if basic > 0 { out.append(0x2D) }
        var n = punyInitialN
        var delta = 0
        var bias = punyInitialBias
        while handled < input.count {
            var next = Int.max
            for value in input where Int(value) >= n && Int(value) < next { next = Int(value) }
            delta += (next - n) * (handled + 1)
            n = next
            for value in input {
                if Int(value) < n { delta += 1 }
                if Int(value) == n {
                    var q = delta
                    var k = punyBase
                    while true {
                        let t = threshold(k, bias)
                        if q < t { break }
                        out.append(punycodeDigit(t + (q - t) % (punyBase - t)))
                        q = (q - t) / (punyBase - t)
                        k += punyBase
                    }
                    out.append(punycodeDigit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return out
    }

    /// The code points an "xn--" label stands for, or nil when its tail is not valid punycode.
    private static func decodePunycode(_ input: [UInt32]) -> [UInt32]? {
        var out: [UInt32] = []
        let delimiter = input.lastIndex(of: 0x2D)
        let basic = delimiter ?? 0
        for value in input[..<basic] {
            guard value < 0x80 else { return nil }
            out.append(value)
        }
        var n = punyInitialN
        var i = 0
        var bias = punyInitialBias
        var position = delimiter.map { $0 + 1 } ?? 0
        let limit = 0x7FFF_FFFF
        while position < input.count {
            let oldI = i
            var w = 1
            var k = punyBase
            while true {
                guard position < input.count else { return nil }
                let char = input[position]
                position += 1
                let digit: Int
                if char >= 0x30, char <= 0x39 {
                    digit = Int(char) - 0x30 + 26
                } else if char >= 0x61, char <= 0x7A {
                    digit = Int(char) - 0x61
                } else if char >= 0x41, char <= 0x5A {
                    digit = Int(char) - 0x41
                } else {
                    return nil
                }
                if digit > (limit - i) / w { return nil }
                i += digit * w
                let t = threshold(k, bias)
                if digit < t { break }
                if w > limit / (punyBase - t) { return nil }
                w *= punyBase - t
                k += punyBase
            }
            bias = adapt(i - oldI, out.count + 1, oldI == 0)
            if i / (out.count + 1) > limit - n { return nil }
            n += i / (out.count + 1)
            i %= out.count + 1
            guard n <= 0x10FFFF, n < 0xD800 || n > 0xDFFF else { return nil }
            out.insert(UInt32(n), at: i)
            i += 1
        }
        return out
    }

    // MARK: IPv4

    /// The IPv4 number parser: decimal, "0x" hex, or "0" octal. Nil when it is not a number. A value past what
    /// four bytes hold is kept as 2^32, which every caller refuses, so no length of digits can overflow.
    private static func parseIPv4Number(_ label: [UInt32]) -> Int? {
        guard !label.isEmpty else { return nil }
        var radix = 10
        var start = 0
        if label.count >= 2, label[0] == 0x30, label[1] == 0x78 || label[1] == 0x58 {
            radix = 16
            start = 2
        } else if label.count >= 2, label[0] == 0x30 {
            radix = 8
            start = 1
        }
        var value = 0
        for char in label[start...] {
            guard let digit = hexValue(char), digit < radix else { return nil }
            value = min(value * radix + digit, 0x1_0000_0000)
        }
        return value
    }

    /// Whether the last label (not counting one empty one at the end) is a number, which makes the host an IPv4
    /// address, or an error.
    private static func endsInANumber(_ domain: [UInt32]) -> Bool {
        var parts = split(domain, on: 0x2E)
        if parts[parts.count - 1].isEmpty {
            if parts.count == 1 { return false }
            parts.removeLast()
        }
        let last = parts[parts.count - 1]
        if !last.isEmpty, last.allSatisfy(isASCIIDigit) { return true }
        return parseIPv4Number(last) != nil
    }

    /// The dotted form of an IPv4 host, or nil when it is not one ("1.2.3.4.5", "256.1.1.1", "a.4").
    private static func parseIPv4(_ domain: [UInt32]) -> String? {
        var parts = split(domain, on: 0x2E)
        if parts[parts.count - 1].isEmpty, parts.count > 1 { parts.removeLast() }
        guard parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = parseIPv4Number(part) else { return nil }
            numbers.append(number)
        }
        for number in numbers.dropLast() where number > 255 { return nil }
        var limit = 1
        for _ in 0..<(5 - numbers.count) { limit *= 256 }
        let last = numbers[numbers.count - 1]
        guard last < limit else { return nil }
        var address = last
        for (position, number) in numbers.dropLast().enumerated() {
            var scale = 1
            for _ in 0..<(3 - position) { scale *= 256 }
            address += number * scale
        }
        let bytes = [(address >> 24) & 255, (address >> 16) & 255, (address >> 8) & 255, address & 255]
        return bytes.map { String($0) }.joined(separator: ".")
    }

    // MARK: IPv6

    /// An IPv6 address between brackets, written the short way ("[0:0:0:0:0:0:0:1]" is "[::1]"), or nil.
    private static func parseIPv6(_ input: [UInt32]) -> String? {
        var pieces = [Int](repeating: 0, count: 8)
        var pieceIndex = 0
        var compress: Int?
        var pointer = 0
        func char(_ at: Int) -> UInt32? { at >= 0 && at < input.count ? input[at] : nil }

        if char(pointer) == 0x3A {
            guard char(pointer + 1) == 0x3A else { return nil }
            pointer += 2
            pieceIndex += 1
            compress = pieceIndex
        }
        while let current = char(pointer) {
            if pieceIndex == 8 { return nil }
            if current == 0x3A {
                if compress != nil { return nil }
                pointer += 1
                pieceIndex += 1
                compress = pieceIndex
                continue
            }
            var value = 0
            var length = 0
            while length < 4, let hex = char(pointer), let digit = hexValue(hex) {
                value = value * 16 + digit
                pointer += 1
                length += 1
            }
            if char(pointer) == 0x2E {
                if length == 0 { return nil }
                pointer -= length
                if pieceIndex > 6 { return nil }
                var numbersSeen = 0
                while char(pointer) != nil {
                    var ipv4Piece: Int?
                    if numbersSeen > 0 {
                        if char(pointer) == 0x2E, numbersSeen < 4 { pointer += 1 } else { return nil }
                    }
                    guard let first = char(pointer), isASCIIDigit(first) else { return nil }
                    while let digitChar = char(pointer), isASCIIDigit(digitChar) {
                        let number = Int(digitChar - 0x30)
                        if let piece = ipv4Piece {
                            if piece == 0 { return nil }
                            ipv4Piece = piece * 10 + number
                        } else {
                            ipv4Piece = number
                        }
                        if let piece = ipv4Piece, piece > 255 { return nil }
                        pointer += 1
                    }
                    pieces[pieceIndex] = pieces[pieceIndex] * 0x100 + (ipv4Piece ?? 0)
                    numbersSeen += 1
                    if numbersSeen == 2 || numbersSeen == 4 { pieceIndex += 1 }
                }
                if numbersSeen != 4 { return nil }
                break
            } else if char(pointer) == 0x3A {
                pointer += 1
                if char(pointer) == nil { return nil }
            } else if char(pointer) != nil {
                return nil
            }
            pieces[pieceIndex] = value
            pieceIndex += 1
        }

        if let compress {
            var swaps = pieceIndex - compress
            pieceIndex = 7
            while pieceIndex != 0, swaps > 0 {
                pieces.swapAt(pieceIndex, compress + swaps - 1)
                pieceIndex -= 1
                swaps -= 1
            }
        } else if pieceIndex != 8 {
            return nil
        }

        // The first longest run of two or more zero pieces becomes "::".
        var bestStart = -1
        var bestLength = 0
        var runStart = 0
        while runStart < 8 {
            guard pieces[runStart] == 0 else {
                runStart += 1
                continue
            }
            var runEnd = runStart
            while runEnd < 8, pieces[runEnd] == 0 { runEnd += 1 }
            if runEnd - runStart > bestLength {
                bestStart = runStart
                bestLength = runEnd - runStart
            }
            runStart = runEnd
        }
        if bestLength < 2 { bestStart = -1 }
        var text = ""
        var skippingZeros = false
        for position in 0..<8 {
            if skippingZeros, pieces[position] == 0 { continue }
            skippingZeros = false
            if bestStart == position {
                text += position == 0 ? "::" : ":"
                skippingZeros = true
                continue
            }
            text += String(pieces[position], radix: 16)
            if position != 7 { text += ":" }
        }
        return "[" + text + "]"
    }

    // MARK: Small pieces

    private static func isASCIILetter(_ value: UInt32) -> Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
    }

    private static func isASCIIDigit(_ value: UInt32) -> Bool {
        value >= 0x30 && value <= 0x39
    }

    private static func isSchemeCharacter(_ value: UInt32) -> Bool {
        isASCIILetter(value) || isASCIIDigit(value) || value == 0x2B || value == 0x2D || value == 0x2E
    }

    private static func isAuthorityEnd(_ value: UInt32) -> Bool {
        value == 0x2F || value == 0x5C || value == 0x3F || value == 0x23
    }

    private static func lowercasedASCII(_ value: UInt32) -> UInt32 {
        value >= 0x41 && value <= 0x5A ? value + 0x20 : value
    }

    private static func hexValue(_ value: UInt32) -> Int? {
        switch value {
        case 0x30...0x39: return Int(value) - 0x30
        case 0x41...0x46: return Int(value) - 0x41 + 10
        case 0x61...0x66: return Int(value) - 0x61 + 10
        default: return nil
        }
    }

    /// Splits on `separator`. Always gives at least one piece, empty when there is nothing, as a JavaScript
    /// `split` does.
    private static func split(_ values: [UInt32], on separator: UInt32) -> [[UInt32]] {
        var parts: [[UInt32]] = [[]]
        for value in values {
            if value == separator { parts.append([]) } else { parts[parts.count - 1].append(value) }
        }
        return parts
    }

    private static func string(from values: [UInt32]) -> String {
        String(String.UnicodeScalarView(values.compactMap { Unicode.Scalar($0) }))
    }
}
