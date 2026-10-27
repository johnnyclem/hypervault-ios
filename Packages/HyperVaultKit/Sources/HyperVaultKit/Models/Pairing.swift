import Foundation

// Pairing: an agent with no key asks for one, shows its person a code, and the person approves it on the website's
// /pair page (the web's source is app/api/pair/**, lib/pairing/{approver,codes,config}.ts and components/pair/).
//
// The app does not approve. The approve and deny routes want a same-origin `Origin` header, which exists to prove
// that a person at a page of the site answered; an app can set any header it likes, so one it set would prove
// nothing. Whether the app may approve at all is the owner's to decide. What it knows about pairing is what a code
// looks like and where the page is, so a `hypervault://pair` link can open the page in Safari.

// MARK: Codes

public enum PairingCode {
    /// No vowels (no accidental words) and nothing that reads as another character (no 0/O, no 1/I/L).
    public static let alphabet = "BCDFGHJKMNPQRSTVWXZ23456789"
    public static let length = 8

    /// The stored form of a code a person typed or followed: upper case, with the spaces, hyphens
    /// and underscores people put in the middle taken out. Nil when what is left is not eight
    /// characters of the alphabet, so a malformed code never costs a lookup.
    public static func normalize(_ input: String) -> String? {
        guard input.count <= 32 else { return nil }
        let kept = input.uppercased().unicodeScalars.filter { scalar in
            !(scalar == " " || scalar == "-" || scalar == "_" || scalar.properties.isWhitespace)
        }
        let code = String(String.UnicodeScalarView(kept))
        guard code.unicodeScalars.count == length, code.unicodeScalars.allSatisfy({ alphabet.unicodeScalars.contains($0) }) else { return nil }
        return code
    }

    /// XXXX-XXXX, the way a code is shown and put in a link.
    public static func format(_ code: String) -> String {
        "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    /// Pulls a code out of what was pasted: a bare code, or the `verification_url` an agent printed.
    public static func extract(from text: String) -> String? {
        if let direct = normalize(text) { return format(direct) }
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "code" || $0.name == "user_code" })?.value,
           let code = normalize(value)
        {
            return format(code)
        }
        // A code inside a sentence: XXXX-XXXX with the alphabet's characters.
        let pattern = "[\(alphabet)]{4}[ -][\(alphabet)]{4}"
        if let range = text.uppercased().range(of: pattern, options: .regularExpression),
           let code = normalize(String(text.uppercased()[range]))
        {
            return format(code)
        }
        return nil
    }
}

// MARK: The page

extension PairingCode {
    /// The website's pairing page, with the code in the link when `code` reads as one. Whatever else was in the
    /// link is dropped: only a code in the alphabet gets into the address.
    public static func pageURL(server: URL, code: String?) -> URL {
        let page = server.appendingPathComponent("pair")
        guard let code, let formatted = extract(from: code),
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { return page }
        components.queryItems = [URLQueryItem(name: "code", value: formatted)]
        return components.url ?? page
    }
}
