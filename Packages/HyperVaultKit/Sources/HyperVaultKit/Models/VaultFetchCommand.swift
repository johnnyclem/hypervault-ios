import Foundation

// "How an agent reads it" on the detail sheet (handoff 5.10, item 5) ends with the command an agent runs:
//
//     curl -s "<app_url>/api/secrets/<name>" \
//       -H "X-HyperVault-Key: hv_YOUR_KEY"
//
// The key in it is a placeholder, never a key: the app holds no hv_ key, and the value route is not one it calls.

extension VaultItems {
    /// What stands where the agent's own key goes. It is shorter than a real key (35 characters), so
    /// `AgentKeyRules.looksLikeKey` does not take it for one.
    public static let fetchKeyPlaceholder = "hv_YOUR_KEY"

    /// The curl command that fetches the secret `name`, for the person to copy and hand to an agent. `appURL` is the
    /// public origin the agent has to call (`capabilities.appUrl`), which can differ from the host the phone
    /// reached (www or the bare domain, a proxy, a staging host); a trailing "/" and white space are dropped, as
    /// the web's `trimOrigin` does. When `appURL` is not an http(s) address and `fallbackOrigin` is, that is
    /// used instead; when neither is, `appURL` is used as given, so the command still shows where it was meant to go.
    ///
    /// A name that follows the rule is written as it is, as on the web. A name from before the rule (a space, a
    /// slash, a quote) is percent-encoded, so it can neither break the quoting in a shell nor change the URL's
    /// path.
    public static func fetchCommand(appURL: String, fallbackOrigin: String? = nil, name: String) -> String {
        var origin = trimmedOrigin(appURL)
        if webHost(origin) == nil, let fallbackOrigin {
            let fallback = trimmedOrigin(fallbackOrigin)
            if webHost(fallback) != nil { origin = fallback }
        }
        let path = isValidName(name) ? name : percentEncodedForPath(name)
        return "curl -s \"\(origin)/api/secrets/\(path)\" \\\n  -H \"X-HyperVault-Key: \(fetchKeyPlaceholder)\""
    }

    /// An origin as it prefixes a path: no white space, no trailing slash (`trimOrigin` in lib/copy.ts).
    private static func trimmedOrigin(_ origin: String) -> String {
        var scalars = Array(jsTrim(origin).unicodeScalars)
        while scalars.last == "/" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Every byte outside `A-Z a-z 0-9 - . _ ~` as %XX.
    private static func percentEncodedForPath(_ name: String) -> String {
        var out = ""
        for byte in name.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += "%" + (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true)
            }
        }
        return out
    }
}
