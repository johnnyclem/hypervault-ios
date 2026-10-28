#!/usr/bin/env python3
"""Generates the app's design tokens from docs/brand/tokens.json.

    gen_tokens.py            write the outputs
    gen_tokens.py --check    write nothing; exit 1 if an output is missing, stale or stray

docs/brand/tokens.json is a copy of the web repo's file of the same name. There, a test
(lib/__tests__/brand-tokens.test.ts) fails when the CSS drifts from it; here, `--check` (run by CI)
fails when the app's outputs drift from the copy. Take a new copy of the file when the web changes,
run this script, and commit the result.

Outputs, all under Shared/DesignSystem so the app, the Share extension and the widgets compile them:

  Colors.xcassets/<token>.colorset   one single-appearance colour set per `stock.color` key, named
                                     for the key, plus the app's own status colours (APP_COLORS).
                                     A colour set always has an Any slot and Xcode defaults it to white;
                                     one universal entry with no appearances means every trait reads
                                     the stock value and nothing can come out white.
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


def colorset(value: str) -> str:
    c = components(value)
    return (
        "{\n"
        '  "colors" : [\n'
        "    {\n"
        '      "color" : {\n'
        '        "color-space" : "srgb",\n'
        f'        "components" : {{ "alpha" : "{c["alpha"]}", "blue" : "{c["blue"]}", '
        f'"green" : "{c["green"]}", "red" : "{c["red"]}" }}\n'
        "      },\n"
        '      "idiom" : "universal"\n'
        "    }\n"
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


def swift(stock: dict, radius_px: dict, fixed: dict) -> str:
    colors = [f'        "{key}": {hex_literal(value)},' for key, value in stock.items()]
    app = [f'        "{key}": {hex_literal(value)},' for key, value in APP_COLORS.items()]
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
        "    /// Colours of the app's own that the web has no token for, by colour set name.",
        "    static let appColors: [String: UInt32] = [",
        *app,
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
    for key, value in {**stock, **APP_COLORS}.items():
        if not HEX.match(value):
            raise SystemExit(f"tokens.json: colour {key} is {value!r}, not #rrggbb in lower case")
    files = {CATALOG / "Contents.json": CATALOG_ROOT}
    for key, value in {**stock, **APP_COLORS}.items():
        files[CATALOG / f"{key}.colorset" / "Contents.json"] = colorset(value)
    for name, key in SYSTEM_COLORS.items():
        files[APP_CATALOG / f"{name}.colorset" / "Contents.json"] = colorset(stock[key])
    files[SWIFT] = swift(stock, tokens["stock"]["radiusPx"], tokens["fixed"])
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
