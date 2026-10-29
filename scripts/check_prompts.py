#!/usr/bin/env python3
"""Every text field in the app passes a `prompt:`, so what it shows when it is empty is the app's own grey.

SwiftUI draws a field's title as its placeholder in the system placeholder colour, which is under 2:1 on the light
page (and 2.6:1 on the dark). `Text.hvPrompt` (and each feature's copy of it: `chatPrompt`, `artifactPrompt`,
`truthPrompt`) is the app's secondary text, which holds 4.5:1. A field that passes none shows the system's.

Reads App/ and Shared/ and fails, with the file and line, on a `TextField(` or `SecureField(` whose arguments have
no `prompt:`, or whose prompt is not given a colour (a bare `Text("...")` is drawn in the system's grey too). Run from
the repository root; CI runs it with the design token check.
"""
import re
import sys
from pathlib import Path

ROOTS = ["App", "Shared"]
FIELD = re.compile(r"\b(TextField|SecureField)\(")
# What gives a prompt the app's grey: the helpers, or a colour put on the Text where it is written.
STYLED = re.compile(r"\b(hvPrompt|chatPrompt|artifactPrompt|truthPrompt)\(|\.foregroundStyle\(")


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


def main() -> int:
    failures = []
    for root in ROOTS:
        for path in sorted(Path(root).rglob("*.swift")):
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
    if failures:
        print("\n".join(failures))
        print(
            f"\n{len(failures)} field(s) would show the system's placeholder grey (under 2:1 on the light look). "
            "Pass prompt: .hvPrompt(...) (or the feature's own: chatPrompt, artifactPrompt, truthPrompt)."
        )
        return 1
    print("every text field passes a prompt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
