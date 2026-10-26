import Foundation

/// How an endpoint's JSON keys map to Swift property names.
public enum KeyStrategy: Sendable {
    /// `source_prompt` <-> `sourcePrompt` (Foundation's standard conversion).
    /// Note `_id` and `_url` become `Id` and `Url`: `artifact_id` is `artifactId`.
    case snakeCase
    /// Keys exactly as the server wrote them. Use with explicit `CodingKeys`
    /// when a response holds dictionaries whose keys must survive (tool input
    /// schemas, headers, labels) or the server mixes casings.
    case verbatim
}

/// The JSON encoder and decoder every HyperVault call uses.
public enum HVCoding {
    public static func decoder(_ keys: KeyStrategy = .snakeCase) -> JSONDecoder {
        let decoder = JSONDecoder()
        if keys == .snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                // Epoch seconds; a value this large is milliseconds.
                return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
            }
            let text = try container.decode(String.self)
            guard let date = HVDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date: \(text)")
            }
            return date
        }
        return decoder
    }

    public static func encoder(_ keys: KeyStrategy = .snakeCase) -> JSONEncoder {
        let encoder = JSONEncoder()
        if keys == .snakeCase { encoder.keyEncodingStrategy = .convertToSnakeCase }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(HVDate.format(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension KeyStrategy: Equatable {}

/// Parsing and writing the timestamps the server speaks: Postgres
/// `timestamptz` text ("2026-10-24T01:02:03.123456+00:00") and JavaScript
/// `toISOString()` ("2026-10-24T01:02:03.123Z"), with or without fractions.
public enum HVDate {
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(normalized(trimmed)) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(normalizedWithoutFraction(trimmed)) {
            return date
        }
        return nil
    }

    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Postgres writes six fractional digits and "+00:00"; trim the fraction to
    /// the three the formatter reads and make a bare offset-less stamp UTC.
    private static func normalized(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else {
            return withZone(addFraction(text))
        }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        var fraction = String(text[text.index(after: dot)..<end])
        fraction = String((fraction + "000").prefix(3))
        let head = text[..<dot]
        let tail = text[end...]
        return withZone(String(head) + "." + fraction + String(tail))
    }

    private static func normalizedWithoutFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return withZone(text) }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        return withZone(String(text[..<dot]) + String(text[end...]))
    }

    private static func addFraction(_ text: String) -> String {
        // "2026-10-24T01:02:03Z" -> "2026-10-24T01:02:03.000Z"
        if let zone = zoneStart(in: text) {
            return String(text[..<zone]) + ".000" + String(text[zone...])
        }
        return text + ".000"
    }

    private static func withZone(_ text: String) -> String {
        zoneStart(in: text) == nil ? text + "Z" : text
    }

    private static func zoneStart(in text: String) -> String.Index? {
        guard let t = text.firstIndex(of: "T") else { return nil }
        let timePart = text[t...]
        if let z = timePart.firstIndex(where: { $0 == "Z" || $0 == "z" || $0 == "+" }) { return z }
        // A minus sign after the time starts a negative offset.
        let afterT = text.index(after: t)
        if let minus = text[afterT...].firstIndex(of: "-") { return minus }
        return nil
    }
}
