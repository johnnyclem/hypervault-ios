#!/usr/bin/env python3
"""Every text field in the app passes a `prompt:`, so what it shows when it is empty is the app's own grey.

SwiftUI draws a field's title as its placeholder in the system placeholder colour, which is under 2:1 on the light
page (and 2.6:1 on the dark). `Text.hvPrompt` (and each feature's copy of it: `chatPrompt`, `artifactPrompt`,
`truthPrompt`) is the app's secondary text, which holds 4.5:1. A field that passes none shows the system's.

Reads App/ and Shared/ and fails, with the file and line, on a `TextField(` or `SecureField(` whose arguments have
no `prompt:`, or whose prompt is not given a colour (a bare `Text("...")` is drawn in the system's grey too). CI runs it
with the design token check.

The same run holds one more line of the design system: colour has one door. `Palette` and `HVColor` read the look the person's
theme is wearing (`StyleRuntime`), so a colour looked up by asset name (`Color("background")`, `UIColor(named:)`) anywhere else
would stay the stock colour under a theme. Only `StyleRuntime.swift` (the stock look) and the tab bar's stock fallback
(`TabBarStyle.swift`) may do it.

And it has a second door for a label: a literal white (or black) as a text or glyph colour (`.foregroundStyle(.white)`,
`.foregroundColor(.white)`, `.tint(.white)`, `Color.white`, `UIColor.white`). On a themed fill it is the label a theme's
own `action_foreground` replaces (the dark kits hold black on a bright action fill), so it is `Palette.onAction` there.
A literal that is right under every theme (a mark on a photo scrim, a card brand's tile) is listed below with the line it
is allowed on.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROOTS = ["App", "Shared"]
FIELD = re.compile(r"\b(TextField|SecureField)\(")
# What gives a prompt the app's grey: the helpers, or the app's own secondary text put on the Text where it is written.
# (`.foregroundStyle(.secondary)` or `.red` would pass a looser test and still be the wrong grey.)
STYLED = re.compile(
    r"\b(hvPrompt|chatPrompt|artifactPrompt|truthPrompt)\(|\.foregroundStyle\(\s*(Palette\.text(Secondary|Tertiary)|HVColor\.mutedForeground)\b"
)


def arguments(text: str, start: int) -> str:
    """The text between the parenthesis that opens at `start - 1` and its match, skipping string literals."""
    depth = 1
    i = start
    in_string = False
    while i < len(text):
        c = text[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start:i]
        i += 1
    return text[start:]


# Where a colour may be looked up by its asset name: the stock look, and the tab bar's stock fallback.
ASSET_LOOKUP = re.compile(r'\bColor\("|\bUIColor\(named:')
ASSET_LOOKUP_ALLOWED = {"Shared/DesignSystem/StyleRuntime.swift", "App/Features/Root/TabBarStyle.swift"}


def swift_lines():
    """Every non-comment line of the app's Swift sources and the extensions' (the files that compile `Shared/`), with its place."""
    for root in ROOTS + ["ShareExtension", "WidgetExtension"]:
        for path in sorted((ROOT / root).rglob("*.swift")):
            relative = path.relative_to(ROOT).as_posix()
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                if not line.lstrip().startswith("//"):
                    yield relative, number, line


def asset_lookups() -> list[str]:
    """Every colour looked up by asset name outside the places allowed to (comments excepted)."""
    found = []
    for relative, number, line in swift_lines():
        if relative in ASSET_LOOKUP_ALLOWED:
            continue
        if ASSET_LOOKUP.search(line):
            found.append(f"{relative}:{number}: a colour looked up by asset name does not follow the theme: {line.strip()}")
    return found


# A label drawn in a literal white or black: as the colour of text or a glyph (`foregroundStyle`, `foregroundColor`, `tint`), or
# `Color.white` / `UIColor.white` wherever it is written. (`.black` as a shadow, a mask or a font weight is not a label.)
LITERAL_LABEL = re.compile(
    r"\.(?:foregroundStyle|foregroundColor|tint)\(\s*(?:Color|UIColor)?\.(?:white|black)\b|\b(?:Color|UIColor)\.white\b"
)
# Where a literal is the right colour under every theme. The stock look is `StyleRuntime.swift` itself (its `onAction` is white).
LITERAL_LABEL_ALLOWED_FILES = {"Shared/DesignSystem/StyleRuntime.swift"}
# The rest, by file and the line (stripped) it is allowed on, so a second one in the same file is a new decision.
LITERAL_LABEL_ALLOWED_LINES = {
    # The brand mark on a card brand's tile: fixed colours, the same under every theme (`HVCardBrandTile`).
    "Shared/DesignSystem/HVCardBrandTile.swift": {".overlay(mark.foregroundStyle(.white))"},
    # The cross of the button that removes a photo from the composer: white on a black disc of its own, over the photo.
    "App/Features/Chat/Conversation/ComposerView.swift": {".foregroundStyle(.white, .black.opacity(0.65))"},
    # The glyph on an artifact's tile, whose fill is seeded from its slug and is the same under every theme.
    "App/Features/Artifacts/ArtifactSupport.swift": {
        "let ink = ArtifactIcon.prefersDarkGlyph(seed: slug) ? Color(hex: 0x0B0F14) : Color.white"
    },
    # A photo is flattened onto white before it is sent as a JPEG: pixels, not a label.
    "App/Features/Chat/Conversation/ChatImagePrep.swift": {"UIColor.white.setFill()"},
}


def literal_labels() -> list[str]:
    """Every literal white or black label outside the places allowed to (comments excepted)."""
    found = []
    for relative, number, line in swift_lines():
        if relative in LITERAL_LABEL_ALLOWED_FILES:
            continue
        if LITERAL_LABEL.search(line) and line.strip() not in LITERAL_LABEL_ALLOWED_LINES.get(relative, set()):
            found.append(f"{relative}:{number}: a literal white or black label does not follow the theme: {line.strip()}")
    return found


def main() -> int:
    failures = []
    scanned = 0
    for root in ROOTS:
        for path in sorted((ROOT / root).rglob("*.swift")):
            scanned += 1
            text = path.read_text()
            for match in FIELD.finditer(text):
                line_start = text.rfind("\n", 0, match.start()) + 1
                if text[line_start:match.start()].lstrip().startswith("//"):
                    continue
                args = arguments(text, match.end())
                line = text.count("\n", 0, match.start()) + 1
                if "prompt:" not in args:
                    failures.append(f"{path}:{line}: {match.group(1)} has no prompt:")
                elif not STYLED.search(args.split("prompt:", 1)[1]):
                    failures.append(f"{path}:{line}: {match.group(1)} has a prompt in the system's grey")
    if scanned == 0:
        print(f"no Swift files under {ROOT}: the lint would pass on nothing")
        return 1
    if failures:
        print("\n".join(failures))
        print(
            f"\n{len(failures)} field(s) would show the system's placeholder grey (under 2:1 on the light look). "
            "Pass prompt: .hvPrompt(...) (or the feature's own: chatPrompt, artifactPrompt, truthPrompt)."
        )
        return 1
    print("every text field passes a prompt")
    lookups = asset_lookups()
    if lookups:
        print("\n".join(lookups))
        print("\nUse Palette (or HVColor) so the colour follows the person's theme. Only StyleRuntime.swift looks colours up by name.")
        return 1
    print("colour has one door: no asset-name lookups outside StyleRuntime")
    labels = literal_labels()
    if labels:
        print("\n".join(labels))
        print(
            "\nA label on a themed fill is Palette.onAction (Palette.onDestructive on the destructive fill), which a theme's own "
            "action_foreground replaces. If the literal is right under every theme (on a photo, in a brand tile), list the line in "
            "scripts/check_prompts.py with the reason."
        )
        return 1
    print("no literal white or black label outside the listed lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
