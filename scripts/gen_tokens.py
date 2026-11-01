#!/usr/bin/env python3
"""Generates the app's design tokens from docs/brand/tokens.json.

    gen_tokens.py            write the outputs
    gen_tokens.py --check    write nothing; exit 1 if an output is missing, stale or stray

docs/brand/tokens.json is a copy of the web repo's file of the same name. There, a test
(lib/__tests__/brand-tokens.test.ts) fails when the CSS drifts from it; here, `--check` (run by CI)
fails when the app's outputs drift from the copy. Take a new copy of the file when the web changes,
run this script, and commit the result.

Outputs, all under Shared/DesignSystem so the app, the Share extension and the widgets compile them:

  Colors.xcassets/<token>.colorset   one colour set per `stock.color` key, named for the key, plus the
                                     app's own status colours (APP_COLORS). Each set has an Any slot and a
                                     Dark slot (both the stock value) and a Light slot (LIGHT, the iOS
                                     guide's mirror). UIColor(named:) returns nil when a set has only
                                     named appearances, so Any is the dark value and never Xcode's white.
  HVTokens.generated.swift           `stock.radiusPx`, `fixed`, and every colour's hex, for the code
                                     and the tests that need the number itself.

and, in the app's own catalog (App/Assets.xcassets), the two colours the system reads by name: AccentColor
(the web's `primary`, which tints controls) and LaunchBackground (the web's `background`, the first frame).

Shadows are not generated: they style chrome that iOS draws itself (handoff 2.6).
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKENS = ROOT / "docs/brand/tokens.json"
OUT = ROOT / "Shared/DesignSystem"
CATALOG = OUT / "Colors.xcassets"
SWIFT = OUT / "HVTokens.generated.swift"
APP_CATALOG = ROOT / "App/Assets.xcassets"
# The colour sets the system looks up by name, and the token each one is.
SYSTEM_COLORS = {"AccentColor": "primary", "LaunchBackground": "background"}

# Colours the app needs that the web has no token for. The web's status chips are plain Tailwind
# emerald-400 and amber-400 (components/api-keys-card.tsx:213-214); Tailwind 4 defines them in OKLCH, partly
# outside sRGB, so these are the clamped sRGB values the handoff gives (handoff 2.1).
APP_COLORS = {
    "emerald-400": "#00d492",
    "amber-400": "#ffb900",
    # The memory kind. Not a web token: the iOS guide's violet, one value in each look.
    "memory": "#a78bfa",
    # The flat fill for anything that carries white text or a white glyph at body size: the person's chat bubbles, the
    # send buttons, the prominent icon button, the count in the Account menu. It is the web's light-look `primary`, in
    # both looks, because white on the dark look's `primary` (#3b82f6) is 3.68:1 and white on this is 5.17:1.
    "action": "#2563eb",
}

# The light look from the iOS guides (color.html, dark_and_light.html). Dark stays the stock value.
# A role the guide does not restate (secondary, the white on a filled button) keeps its dark value,
# so the two looks do not invent a second meaning for it. Success, warning and memory darken in the
# light look, where the bright dark-look shades fail as text on white paper.
LIGHT = {
    "background": "#f5f7fa",
    "foreground": "#0b0f14",
    "card": "#ffffff",
    "card-foreground": "#0b0f14",
    "muted": "#e9eef5",
    "muted-foreground": "#536176",
    "primary": "#2563eb",
    "primary-foreground": "#ffffff",
    "secondary": "#64748b",
    "secondary-foreground": "#f8fafc",
    "accent": "#0369a1",
    "accent-foreground": "#ffffff",
    "border": "#d3dce8",
    "ring": "#2563eb",
    "destructive": "#dc2626",
    "emerald-400": "#047857",
    "amber-400": "#b45309",
    "memory": "#6d28d9",
    "action": "#2563eb",
}

# tokens.json's schema says the right Mastercard disc "is drawn at 90% opacity"; the value is prose there.
MASTERCARD_RIGHT_OPACITY = 0.9

HEX = re.compile(r"^#[0-9a-f]{6}$")
RGBA = re.compile(r"^rgb\((\d+) (\d+) (\d+) / ([0-9.]+)\)$")


def camel(token: str) -> str:
    head, *rest = token.split("-")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def hex_literal(value: str) -> str:
    return "0x" + value[1:].upper()


def components(value: str) -> dict:
    red, green, blue = (int(value[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return {"red": f"{red:.6f}", "green": f"{green:.6f}", "blue": f"{blue:.6f}", "alpha": "1.000"}


def color_body(value: str) -> str:
    c = components(value)
    return (
        '      "color" : {\n'
        '        "color-space" : "srgb",\n'
        f'        "components" : {{ "alpha" : "{c["alpha"]}", "blue" : "{c["blue"]}", '
        f'"green" : "{c["green"]}", "red" : "{c["red"]}" }}\n'
        "      },\n"
    )


def slot(value: str, appearance: str) -> str:
    return (
        "    {\n"
        f"{color_body(value)}"
        "      \"appearances\" : [\n"
        "        {\n"
        "          \"appearance\" : \"luminosity\",\n"
        f"          \"value\" : \"{appearance}\"\n"
        "        }\n"
        "      ],\n"
        '      "idiom" : "universal"\n'
        "    }"
    )


def any_slot(value: str) -> str:
    """The slot with no appearance. UIKit needs one or `UIColor(named:)` returns nil."""
    return (
        "    {\n"
        f"{color_body(value)}"
        '      "idiom" : "universal"\n'
        "    }"
    )


def colorset(dark: str, light: str) -> str:
    return (
        "{\n"
        '  "colors" : [\n'
        f"{any_slot(dark)},\n"
        f"{slot(dark, 'dark')},\n"
        f"{slot(light, 'light')}\n"
        "  ],\n"
        '  "info" : {\n'
        '    "author" : "xcode",\n'
        '    "version" : 1\n'
        "  }\n"
        "}\n"
    )


CATALOG_ROOT = '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'


def fixed_constants(fixed: dict) -> list:
    """`fixed` as Swift constants: a hex colour is one UInt32; an rgb(r g b / a) is a hex and an opacity."""
    lines = []
    for key, value in fixed.items():
        name = camel(key)
        if HEX.match(value):
            lines.append(f"        static let {name}: UInt32 = {hex_literal(value)}")
            continue
        match = RGBA.match(value)
        if not match:
            raise SystemExit(f"tokens.json: fixed.{key} is {value!r}, which is neither #rrggbb nor rgb(r g b / a)")
        red, green, blue = (int(match.group(i)) for i in (1, 2, 3))
        lines.append(f"        static let {name}: UInt32 = 0x{red:02X}{green:02X}{blue:02X}")
        lines.append(f"        static let {name}Opacity = {match.group(4)}")
    if "card-mastercard-right" in fixed:
        lines.append(f"        static let cardMastercardRightOpacity = {MASTERCARD_RIGHT_OPACITY}")
    return lines


def swift(stock: dict, radius_px: dict, fixed: dict, light: dict) -> str:
    colors = [f'        "{key}": {hex_literal(value)},' for key, value in stock.items()]
    app = [f'        "{key}": {hex_literal(value)},' for key, value in APP_COLORS.items()]
    mirrors = [f'        "{key}": {hex_literal(light[key])},' for key in list(stock) + list(APP_COLORS)]
    radii = [f"        static let {camel(key)}: CGFloat = {value}" for key, value in radius_px.items()]
    return "\n".join([
        "// Generated by scripts/gen_tokens.py from docs/brand/tokens.json. Do not edit by hand:",
        "// `python3 scripts/gen_tokens.py` rewrites it and `--check` fails when it is stale.",
        "",
        "import CoreGraphics",
        "",
        "/// The web's stock tokens as plain numbers. Colours on screen come from the catalog (`HVColor`);",
        "/// these are for the code that needs the value itself: the fixed colours of the code panel and the",
        "/// card brands, the radii, and the tests that hold the catalog to tokens.json.",
        "enum HVTokens {",
        "    /// `stock.radiusPx`, in points (1 CSS px is 1 pt).",
        "    enum RadiusPx {",
        *radii,
        "    }",
        "",
        "    /// `stock.color`: 0xRRGGBB by token name, which is also the name of its colour set.",
        "    static let stockColors: [String: UInt32] = [",
        *colors,
        "    ]",
        "",
        "    /// Colours of the app's own that the web has no token for, by colour set name. The dark slot.",
        "    static let appColors: [String: UInt32] = [",
        *app,
        "    ]",
        "",
        "    /// The light slot of every colour set: the iOS guide's mirror of the dark value.",
        "    static let lightColors: [String: UInt32] = [",
        *mirrors,
        "    ]",
        "",
        "    /// `fixed`: colours drawn outside the tokens, which no theme changes.",
        "    enum Fixed {",
        *fixed_constants(fixed),
        "    }",
        "}",
        "",
    ])


def outputs() -> dict:
    tokens = json.loads(TOKENS.read_text())
    stock = tokens["stock"]["color"]
    catalog = {**stock, **APP_COLORS}
    missing = [key for key in catalog if key not in LIGHT]
    if missing:
        raise SystemExit(f"gen_tokens.py: no light mirror for {', '.join(missing)}")
    for key, value in {**catalog, **LIGHT}.items():
        if not HEX.match(value):
            raise SystemExit(f"colour {key} is {value!r}, not #rrggbb in lower case")
    files = {CATALOG / "Contents.json": CATALOG_ROOT}
    for key, value in catalog.items():
        files[CATALOG / f"{key}.colorset" / "Contents.json"] = colorset(value, LIGHT[key])
    for name, key in SYSTEM_COLORS.items():
        files[APP_CATALOG / f"{name}.colorset" / "Contents.json"] = colorset(stock[key], LIGHT[key])
    files[SWIFT] = swift(stock, tokens["stock"]["radiusPx"], tokens["fixed"], LIGHT)
    return files


def problems(files: dict) -> list:
    found = []
    for path, text in files.items():
        shown = path.relative_to(ROOT)
        if not path.exists():
            found.append(f"missing: {shown}")
        elif path.read_text() != text:
            found.append(f"stale: {shown}")
    if CATALOG.exists():
        for path in sorted(CATALOG.rglob("*")):
            if path.is_file() and path not in files:
                found.append(f"stray: {path.relative_to(ROOT)}")
    return found


def main(argv: list) -> int:
    files = outputs()
    if "--check" in argv:
        found = problems(files)
        for line in found:
            print(line)
        if found:
            print("The design tokens are out of step with docs/brand/tokens.json: run `make tokens`.")
            return 1
        print(f"The design tokens match docs/brand/tokens.json ({len(files)} files).")
        return 0
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    for path in sorted(CATALOG.rglob("*")) if CATALOG.exists() else []:
        if path.is_file() and path not in files:
            path.unlink()
            print(f"removed {path.relative_to(ROOT)}")
    print(f"Wrote {len(files)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
