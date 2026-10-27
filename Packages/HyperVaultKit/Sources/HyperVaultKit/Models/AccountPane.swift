import Foundation

// The panes of the You page, ported from components/settings/account-tabs.ts. The web page is `/vault/account`;
// `?tab=<id>` picks the pane on the server and the URL hash picks it in the browser, and links already in the
// wild use both (`/vault/account#keys`, `/vault/account#secrets`). The ids are load-bearing for that reason, and
// four old section ids stay as aliases for the pane that holds what they pointed at.

/// One pane of the You page. The raw value is the id a link uses.
public enum AccountPane: String, CaseIterable, Identifiable, Sendable {
    case general, vault, keys, backends, domain, appearance
    case `import`

    public var id: String { rawValue }

    /// The pane shown when a link names none: the vault is what this page is for.
    public static let `default` = AccountPane.vault

    /// The pane's name in the list and as its heading. "Agent keys" is quoted by the agent docs ("open Agent
    /// keys, then Generate a key"), so it is never reworded on its own.
    public var label: String {
        switch self {
        case .general: return "General"
        case .vault: return "Vault"
        case .keys: return "Agent keys"
        case .backends: return "Models"
        case .domain: return "Domain"
        case .appearance: return "Appearance"
        case .import: return "Import"
        }
    }

    /// The SF Symbol for the pane (handoff 2.7).
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .vault: return "lock"
        case .keys: return "key"
        case .backends: return "sparkles"
        case .domain: return "globe"
        case .appearance: return "paintpalette"
        case .import: return "square.and.arrow.down"
        }
    }

    /// The line under the pane's heading, verbatim from the web (components/account-sections.tsx; the brand book,
    /// section 4, "Places", quotes all of them but Models, whose line it cuts short, so that one is the code's).
    /// The Agent keys line is the default one. The web adds "1 agent connected." once a key has passed its setup
    /// challenge; the server works that out and a native client must not show it (handoff 5.10).
    public var descriptionLine: String {
        switch self {
        case .general:
            return "The account you are signed in with."
        case .vault:
            return "Save a login, card or contact once. Agents you give a key, like Claude Code, Codex, Cursor, Gemini CLI or your own script, can use it, and only the ones you allow."
        case .keys:
            return "One key per agent. A key is shown once, and comes with a setup challenge the agent completes to prove the link works."
        case .backends:
            return "What answers when you ask something, on the canvas and in Chat. Pick a provider, paste its API key, and press Connect. The canvas uses the newest one; Chat lets you pick one per conversation."
        case .domain:
            return "Every claimed address serves your whole vault. Visitors see the realm's look; you still get your dashboard."
        case .appearance:
            return "One look for your dashboard and chat; each realm can wear its own, and open straight to an artifact you pick."
        case .import:
            return "Bring what you made elsewhere into your vault."
        }
    }

    /// Ids from the page when it was one long scroll, and the pane that holds that section now.
    public static let aliases: [(name: String, pane: AccountPane)] = [
        (name: "secrets", pane: .vault),
        (name: "reference", pane: .keys),
        (name: "theme", pane: .appearance),
        (name: "import-file", pane: .import),
    ]

    // MARK: Resolving a link

    /// The pane a `?tab=` value or a URL hash names, or nil when it names none (`resolveAccountTab`). Drops ONE
    /// leading "#" (so `location.hash` can be passed as it is, and "##keys" names nothing), trims with
    /// JavaScript's white space, and matches exactly: the match is case-sensitive, so "Vault" names nothing.
    /// A value that is not there (a missing `tab`) names nothing.
    public static func resolve(_ raw: String?) -> AccountPane? {
        guard let raw else { return nil }
        var scalars = raw.unicodeScalars
        if scalars.first == "#" { scalars.removeFirst() }
        // Compared as bytes: String equality is canonical equivalence, and a link id is plain ASCII.
        let wanted = Array(VaultItems.jsTrim(String(scalars)).utf8)
        if let pane = allCases.first(where: { Array($0.rawValue.utf8) == wanted }) { return pane }
        return aliases.first(where: { Array($0.name.utf8) == wanted })?.pane
    }

    /// The pane a link opens. A `tab` item that names a pane wins, and only if there is exactly one: a repeated
    /// `?tab=` names nothing (Next hands the page an array). Otherwise the hash decides, and otherwise the
    /// default. `fragment` is the part after the "#" in the form `location.hash` holds it, which is
    /// `URLComponents.percentEncodedFragment` (an encoded "%76ault" is not "vault" in the browser either).
    public static func resolve(queryItems: [URLQueryItem], fragment: String?) -> AccountPane {
        let tabs = queryItems.filter { $0.name == "tab" }
        if tabs.count == 1, let pane = resolve(tabs[0].value) { return pane }
        if let fragment, let pane = resolve("#" + fragment) { return pane }
        return .default
    }
}
