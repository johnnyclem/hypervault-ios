import Foundation

// The web dashboard's theme: the look the person's signed-in pages on the website wear (/vault, /chat, /admin).
// The web keeps it in `profiles.theme` (a style id from `GET /api/capabilities` `themes`, or null for the stock
// look), reads it under row-level security, and changes it with `PATCH /api/dashboard-theme`
// (app/api/dashboard-theme/route.ts, lib/dashboard-theme.ts, components/theme-switcher.tsx).
//
// The app does not wear it: the stock look is the only one the app draws (handoff 2.3). So the words here never
// say the app changed, and the stock choice is not called "Gsap", which the web's select does although choosing it
// renders the stock look.

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

/// `PATCH /api/dashboard-theme`: the theme the profile holds now.
public struct DashboardThemeSaved: Sendable, Equatable, Decodable {
    public let theme: String?
    public let message: String?
}

extension Endpoint where Response == DashboardThemeSaved {
    /// Sets the web dashboard's theme. A nil id is the stock look (`null` on the wire). An id the server does not
    /// know is a 400 whose sentence lists every id; the picker only offers ids from the catalog, so it is not shown.
    public static func setDashboardTheme(_ theme: String?) -> Endpoint<DashboardThemeSaved> {
        Endpoint(.patch, "/api/dashboard-theme", body: .jsonValue(["theme": theme.map(JSONValue.string) ?? .null]))
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
