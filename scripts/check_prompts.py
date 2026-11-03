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


def asset_lookups() -> list[str]:
    """Every colour looked up by asset name outside the places allowed to (comments excepted)."""
    found = []
    for root in ROOTS + ["ShareExtension", "WidgetExtension"]:
        for path in sorted((ROOT / root).rglob("*.swift")):
            relative = path.relative_to(ROOT).as_posix()
            if relative in ASSET_LOOKUP_ALLOWED:
                continue
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                if line.lstrip().startswith("//"):
                    continue
                if ASSET_LOOKUP.search(line):
                    found.append(f"{relative}:{number}: a colour looked up by asset name does not follow the theme: {line.strip()}")
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
