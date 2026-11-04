import Foundation
import HyperVaultKit

// The kits the app's tests wear. The first four are the server's golden files (docs/stylekit/fixtures), the ones
// Packages/HyperVaultKit/Tests/HyperVaultKitTests/Fixtures/stylekit holds; the rest are the same builder's answer for that
// theme (all-presets.json there). The Kit's tests read them as files and hold them to the floors; a test target cannot read
// the package's resources, so here they are text, and `StyleRuntimeTests.testEveryFixtureIsAKitTheAppMayWear` holds each to
// the same floors. When the server changes a theme, copy the new JSON over from those files.

enum StyleKitFixtures {
    /// A kit from the server's JSON. A fixture that is not one is a mistake in this file, and fails the run at once.
    static func kit(_ json: String) -> StyleKit {
        do {
            return try JSONDecoder().decode(StyleKit.self, from: Data(json.utf8))
        } catch {
            fatalError("A StyleKit fixture does not decode: \(error)")
        }
    }

    /// The four goldens: a serif light theme, a translucent dark theme with a black label, the light stock and the dark stock.
    static let goldens: [StyleKit] = [newsprint, glassmorphism, hypervaultLight, modernDark]

    /// Every fixture, in the order above and then the rest.
    static let all: [StyleKit] = goldens + [memoryVault, terminal, auroraMesh, industrial]

    static let newsprint = kit(#"""
{
  "schema_version": 1,
  "id": "newsprint",
  "name": "Newsprint",
  "appearance": "light",
  "colors": {
    "background": "#f6f3ea",
    "foreground": "#17150f",
    "card": "#fffdf4",
    "muted": "#eae5d6",
    "muted_foreground": "#5c574a",
    "primary": "#17150f",
    "accent": "#a41623",
    "destructive": "#dd1313",
    "success": "#1b5929",
    "warning": "#843603",
    "action": "#17150f",
    "action_foreground": "#fffdf4",
    "border": "#17150f",
    "ring": "#a41623"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "serif"
  },
  "backdrop": {
    "kind": "lines"
  },
  "adjusted": [
    "destructive"
  ]
}
"""#)

    static let glassmorphism = kit(#"""
{
  "schema_version": 1,
  "id": "glassmorphism",
  "name": "Glassmorphism",
  "appearance": "dark",
  "colors": {
    "background": "#0b1120",
    "foreground": "#eef4ff",
    "card": "#1a1f2d",
    "muted": "#1f2432",
    "muted_foreground": "#9db1d4",
    "primary": "#7678f3",
    "accent": "#38bdf8",
    "destructive": "#f04a4a",
    "success": "#00d492",
    "warning": "#ffb900",
    "action": "#6366f1",
    "action_foreground": "#000000",
    "border": "#2d323f",
    "ring": "#38bdf8"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "system"
  },
  "backdrop": {
    "kind": "glow"
  },
  "adjusted": [
    "primary",
    "destructive",
    "action_foreground"
  ]
}
"""#)

    static let hypervaultLight = kit(#"""
{
  "schema_version": 1,
  "id": "hypervault-light",
  "name": "HyperVault Light",
  "appearance": "light",
  "colors": {
    "background": "#f6f1e7",
    "foreground": "#2a2118",
    "card": "#fffdf8",
    "muted": "#f1e4c6",
    "muted_foreground": "#6b5e4b",
    "primary": "#845300",
    "accent": "#426558",
    "destructive": "#9b1c36",
    "success": "#1b5929",
    "warning": "#843603",
    "action": "#845300",
    "action_foreground": "#fffdf8",
    "border": "#e6dcc6",
    "ring": "#845300"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "system"
  },
  "backdrop": {
    "kind": "glow"
  },
  "adjusted": []
}
"""#)

    static let modernDark = kit(#"""
{
  "schema_version": 1,
  "id": "modern-dark",
  "name": "Modern Dark",
  "appearance": "dark",
  "colors": {
    "background": "#0b0f14",
    "foreground": "#e8eef5",
    "card": "#121820",
    "muted": "#1a222d",
    "muted_foreground": "#8b97a8",
    "primary": "#3b82f6",
    "accent": "#38bdf8",
    "destructive": "#ef4444",
    "success": "#00d492",
    "warning": "#ffb900",
    "action": "#3b82f6",
    "action_foreground": "#000000",
    "border": "#243041",
    "ring": "#3b82f6"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "system"
  },
  "backdrop": {
    "kind": "glow"
  },
  "adjusted": [
    "action_foreground"
  ]
}
"""#)

    static let memoryVault = kit(#"""
{
  "schema_version": 1,
  "id": "memory-vault",
  "name": "Memory Vault",
  "appearance": "light",
  "colors": {
    "background": "#faf5eb",
    "foreground": "#2d3436",
    "card": "#ffffff",
    "muted": "#f0e6d6",
    "muted_foreground": "#5f6a6e",
    "primary": "#e30000",
    "accent": "#7c6600",
    "destructive": "#dd1c2b",
    "success": "#1b5929",
    "warning": "#843603",
    "action": "#ff6b6b",
    "action_foreground": "#000000",
    "border": "#ebdcc7",
    "ring": "#4ecdc4"
  },
  "radius": {
    "base": 24
  },
  "font": {
    "design": "system"
  },
  "backdrop": {
    "kind": "glow"
  },
  "adjusted": [
    "muted_foreground",
    "primary",
    "accent",
    "destructive",
    "action_foreground"
  ]
}
"""#)

    static let terminal = kit(#"""
{
  "schema_version": 1,
  "id": "terminal",
  "name": "Terminal CLI",
  "appearance": "dark",
  "colors": {
    "background": "#000000",
    "foreground": "#33ff33",
    "card": "#030a03",
    "muted": "#0a1a0a",
    "muted_foreground": "#1fbf1f",
    "primary": "#33ff33",
    "accent": "#33ff33",
    "destructive": "#ef4444",
    "success": "#00d492",
    "warning": "#ffb900",
    "action": "#33ff33",
    "action_foreground": "#000000",
    "border": "#1a801a",
    "ring": "#33ff33"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "mono"
  },
  "backdrop": {
    "kind": "lines"
  },
  "adjusted": []
}
"""#)

    static let auroraMesh = kit(#"""
{
  "schema_version": 1,
  "id": "aurora-mesh",
  "name": "Aurora Mesh",
  "appearance": "dark",
  "colors": {
    "background": "#08041a",
    "foreground": "#f4f1ff",
    "card": "#120b2e",
    "muted": "#1c1440",
    "muted_foreground": "#a9a3c9",
    "primary": "#925cf0",
    "accent": "#2dd4bf",
    "destructive": "#ef4444",
    "success": "#00d492",
    "warning": "#ffb900",
    "action": "#7c3aed",
    "action_foreground": "#ffffff",
    "border": "#2b2154",
    "ring": "#7c3aed"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "system"
  },
  "backdrop": {
    "kind": "glow"
  },
  "adjusted": [
    "primary"
  ]
}
"""#)

    static let industrial = kit(#"""
{
  "schema_version": 1,
  "id": "industrial",
  "name": "Industrial",
  "appearance": "light",
  "colors": {
    "background": "#d6d5d0",
    "foreground": "#1f1e1a",
    "card": "#e4e3de",
    "muted": "#c8c7c0",
    "muted_foreground": "#54544b",
    "primary": "#a13c08",
    "accent": "#913607",
    "destructive": "#ba1010",
    "success": "#1b5929",
    "warning": "#843603",
    "action": "#ea580c",
    "action_foreground": "#000000",
    "border": "#a8a7a3",
    "ring": "#ea580c"
  },
  "radius": {
    "base": 12
  },
  "font": {
    "design": "system"
  },
  "backdrop": {
    "kind": "plain"
  },
  "adjusted": [
    "muted_foreground",
    "primary",
    "accent",
    "destructive",
    "action_foreground"
  ]
}
"""#)
}
