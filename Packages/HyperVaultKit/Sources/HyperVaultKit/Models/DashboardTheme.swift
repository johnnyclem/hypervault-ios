import Foundation

// The web dashboard's theme: the look the person's signed-in pages on the website wear (/vault, /chat, /admin).
// The web keeps it in `profiles.theme` (a style id from `GET /api/capabilities` `themes`, or null for the stock
// look) and changes it with `PATCH /api/dashboard-theme` (app/api/dashboard-theme/route.ts, lib/dashboard-theme.ts,
// components/theme-switcher.tsx).
//
// The app wears it too, from a server that sends kits (`Capabilities.Features.stylekit`): `GET /api/dashboard-theme`
// answers `{ theme, kit }`, where `kit` is the accessible StyleKit the server derived for the theme (Style/StyleKit.swift).
// A server that predates the kit has no GET, so the id is read from `profiles` under row-level security as before and the
// app keeps its own default look. The words in `DashboardThemeCopy` are from before the app wore anything and say it
// does not; they change when the pane switches over. The stock choice is not called "Gsap", which the web's select does
// although choosing it renders the stock look.

// MARK: Choices

/// One entry of the theme picker.
public struct DashboardThemeChoice: Sendable, Hashable {
    /// The id the server stores, or nil for the stock look.
    public let themeID: String?
    public let label: String

    public init(themeID: String?, label: String) {
        self.themeID = themeID
        self.label = label
    }
}

public enum DashboardThemes {
    /// What the empty choice is called: the web says "HyperVault default" and then names a theme after it, which is
    /// wrong, because choosing it renders the stock look.
    public static let stockLabel = "HyperVault default"

    /// The picker's entries: the stock look first, then the server's catalog in the server's order, each as the web
    /// writes it ("Glassmorphism (dark)"). An id the catalog lists twice is offered once.
    public static func choices(from catalog: [Capabilities.ThemeInfo]) -> [DashboardThemeChoice] {
        var seen = Set<String>()
        var choices = [DashboardThemeChoice(themeID: nil, label: stockLabel)]
        for theme in catalog where seen.insert(theme.id).inserted {
            choices.append(DashboardThemeChoice(themeID: theme.id, label: "\(theme.name) (\(theme.mode))"))
        }
        return choices
    }

    /// The id the picker shows as chosen: the stored one when the catalog lists it, otherwise the stock look, which
    /// is what the web renders for an id it does not know (lib/dashboard-theme.ts).
    public static func selection(stored: String?, in catalog: [Capabilities.ThemeInfo]) -> String? {
        guard let stored, catalog.contains(where: { $0.id == stored }) else { return nil }
        return stored
    }

    /// The theme's name, or nil for the stock look and for an id the catalog does not list.
    public static func name(of id: String?, in catalog: [Capabilities.ThemeInfo]) -> String? {
        guard let id else { return nil }
        return catalog.first { $0.id == id }?.name
    }
}

/// The words around the picker. New copy: the web's ("Your dashboard & chat", "Theme for your dashboard and chat",
/// "Saved") would say that the app's own look changed.
public enum DashboardThemeCopy {
    public static let line = "How your dashboard and chat look on the website."
    public static let sectionTitle = "On the website"
    public static let pickerLabel = "Theme for the website"
    public static let footer = "This app keeps the HyperVault default look, whatever you pick here. The look of each address you claim is under Domain."
    public static let saving = "Saving"

    /// What the server agreed to, once it has: said about the website, and about the name the catalog gives the theme.
    public static func confirmation(for id: String?, in catalog: [Capabilities.ThemeInfo]) -> String {
        guard let id else { return "Your website is back on the HyperVault default look." }
        let name = DashboardThemes.name(of: id, in: catalog) ?? id
        return "Your website now wears \(name)."
    }
}

// MARK: Wire

/// What the server says the app should wear for the person's dashboard theme: `GET /api/dashboard-theme`, and the same
/// keys in the answer to `PATCH`. `kit` is nil, and `reason` says why, whenever the app keeps its own default look.
///
/// Reading is forgiving about the kit and strict about the response: a response that is not a JSON object with a string
/// or null `theme` fails to decode (a failed refresh keeps what is worn), while a kit the app cannot read or that fails
/// the accessibility floors becomes `kit: nil, reason: .invalid`, because the server asked for a look the app must not
/// wear and the default look is the answer. Whatever has decoded has passed `StyleKit.violations`, so a `kit` here is
/// always safe to draw. The same type is what the disk cache holds, so a build with stricter floors re-checks it on read.
///
/// Decode with `keys: .verbatim`: the kit spells its keys out (`schema_version`, `muted_foreground`).
public struct DashboardThemeState: Sendable, Equatable, Codable {
    /// Why `kit` is nil though `theme` is set.
    public enum Reason: String, Sendable, Codable, Equatable {
        /// The stored id is not in the server's catalog any more. The web shows its stock look; so does the app.
        case unknown
        /// The server has no accessible kit for this theme (`retro`), or does not send kits at all. The app keeps its
        /// default look and says the theme cannot be shown. An unrecognised reason word reads as this too.
        case unsupported
        /// The server sent a kit this build cannot read (a newer `schema_version`, a missing colour, a colour that is not
        /// opaque `#rrggbb`) or that fails the accessibility floors. Never sent by a server: made here.
        case invalid
    }

    /// The raw `profiles.theme`: a style id, or nil for the stock look.
    public let theme: String?
    /// The look to wear; nil to keep the app's own default.
    public let kit: StyleKit?
    /// Set exactly when `theme` is set and `kit` is nil.
    public let reason: Reason?

    /// `theme` nil is the default look and carries no kit; a kit carries no reason; a theme with neither a kit nor a
    /// reason is one the server did not explain, which is `unsupported`.
    public init(theme: String?, kit: StyleKit? = nil, reason: Reason? = nil) {
        guard let theme else {
            self.theme = nil
            self.kit = nil
            self.reason = nil
            return
        }
        self.theme = theme
        if let kit, kit.violations.isEmpty {
            self.kit = kit
            self.reason = nil
        } else {
            self.kit = nil
            self.reason = kit == nil ? (reason ?? .unsupported) : .invalid
        }
    }

    /// No theme: the app wears its own default look.
    public static let stock = DashboardThemeState(theme: nil)

    /// Whether the person has a theme the app is keeping off, and should say so (`unknown` is not: the web shows stock
    /// for it too).
    public var isWithheld: Bool { theme != nil && kit == nil && reason != .unknown }

    enum Keys: String, CodingKey { case theme, kit, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let theme = try c.decodeIfPresent(String.self, forKey: .theme)
        var kit: StyleKit?
        var unreadable = false
        if c.contains(.kit) {
            let isNull = try c.decodeNil(forKey: .kit)
            if !isNull {
                do { kit = try c.decode(StyleKit.self, forKey: .kit) } catch { unreadable = true }
            }
        }
        let word = try? c.decodeIfPresent(String.self, forKey: .reason)
        let reason = unreadable ? Reason.invalid : word.map { Reason(rawValue: $0) ?? .unsupported }
        self.init(theme: theme, kit: kit, reason: reason)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(theme, forKey: .theme)
        try c.encode(kit, forKey: .kit)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

/// `PATCH /api/dashboard-theme`: the theme the profile holds now, and the look the server derived for it, so a saved
/// choice can be worn without asking again.
public struct DashboardThemeSaved: Sendable, Equatable, Decodable {
    public let theme: String?
    public let message: String?
    /// The same `theme`, `kit` and `reason` a `GET` would answer. A server that predates kits sends none, which reads
    /// as `unsupported` for a theme and as the default look for none.
    public let state: DashboardThemeState

    public init(theme: String?, message: String? = nil, state: DashboardThemeState? = nil) {
        self.theme = theme
        self.message = message
        self.state = state ?? DashboardThemeState(theme: theme)
    }

    enum Keys: String, CodingKey { case message }

    public init(from decoder: Decoder) throws {
        let state = try DashboardThemeState(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(theme: state.theme, message: try c.decodeIfPresent(String.self, forKey: .message), state: state)
    }
}

extension Endpoint where Response == DashboardThemeSaved {
    /// Sets the web dashboard's theme. A nil id is the stock look (`null` on the wire). An id the server does not
    /// know is a 400 whose sentence lists every id; the picker only offers ids from the catalog, so it is not shown.
    /// Verbatim keys: the answer carries a kit, which spells its own.
    public static func setDashboardTheme(_ theme: String?) -> Endpoint<DashboardThemeSaved> {
        Endpoint(.patch, "/api/dashboard-theme", body: .jsonValue(["theme": theme.map(JSONValue.string) ?? .null]), keys: .verbatim)
    }
}

extension Endpoint where Response == DashboardThemeState {
    /// The look the person's theme resolves to. Only a server that says `features.stylekit` has it; an older one answers
    /// 404 or 405, which `HVClient.dashboardThemeState()` reads as "no kit". Verbatim keys: the kit spells its own.
    public static var dashboardTheme: Endpoint<DashboardThemeState> {
        Endpoint(.get, "/api/dashboard-theme", keys: .verbatim)
    }
}

extension HVClient {
    /// The person's theme and kit, or nil from a server that predates the GET (Next.js answers 405 for a method a route
    /// does not export, 404 if the route is missing). Any other failure throws: a blip must not read as "no theme" and
    /// flip the app to its default look.
    public func dashboardThemeState() async throws -> DashboardThemeState? {
        do {
            return try await send(.dashboardTheme)
        } catch let error as HVError where error.failure?.status == 404 || error.failure?.status == 405 {
            return nil
        }
    }
}

private struct ProfileThemeRow: Decodable, Sendable {
    let theme: String?
}

extension AccountRest {
    /// The theme the person's web dashboard wears (`profiles.theme`), or nil for the stock look. A database from
    /// before the column has none to read: the web degrades to the stock look there, and so does this.
    public func dashboardTheme(userID: String) async throws -> String? {
        do {
            let rows: [ProfileThemeRow] = try await rows(
                from: "profiles",
                query: [
                    URLQueryItem(name: "select", value: "theme"),
                    URLQueryItem(name: "id", value: "eq.\(userID)"),
                    URLQueryItem(name: "limit", value: "1"),
                ]
            )
            return rows.first?.theme
        } catch where Self.isMissingColumn(error) {
            return nil
        }
    }
}
