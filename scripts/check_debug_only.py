#!/usr/bin/env python3
"""Checks that the UI-test mode cannot be compiled into a release build.

    check_debug_only.py

The mode (App/Core/UITestHarness.swift, UITestWorld.swift, UITestWorld+Screens.swift, UITestWorld+Writes.swift, UITestWrites.swift, and the scratch defaults in Shared/SharedConfig.swift) is
meant to exist only in debug builds. This reads the sources and fails if

  - a harness file is not wrapped, whole, in `#if DEBUG ... #endif`, or
  - any other file under App/ or Shared/ names one of the harness' symbols outside a `#if DEBUG` block.

CI builds Release only to compile it, which would not show the mode reachable, so this is the check that a release build
has no way into the mode.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HARNESS_FILES = [
    ROOT / "App/Core/UITestHarness.swift",
    ROOT / "App/Core/UITestWorld.swift",
    ROOT / "App/Core/UITestWorld+Screens.swift",
    ROOT / "App/Core/UITestWorld+Writes.swift",
    ROOT / "App/Core/UITestWrites.swift",
]
SYMBOLS = re.compile(r"\b(UITestHarness|UITestWorld|UITestScenario|UITestURLProtocol|UITestSecureStore|UITestWriteLog|UITestWritesModel|UITestWritesBeacon|UITestRecordingTransport|scratchDefaults)\b")


def significant(lines):
    return [line.strip() for line in lines if line.strip()]


def main() -> int:
    problems = []

    for path in HARNESS_FILES:
        lines = significant(path.read_text().splitlines())
        if not lines or lines[0] != "#if DEBUG" or lines[-1] != "#endif":
            problems.append(f"{path.relative_to(ROOT)} is not wrapped, whole, in #if DEBUG ... #endif")
        depth = 0
        for line in lines[1:-1]:
            if line.startswith("#if"):
                depth += 1
            elif line.startswith("#endif"):
                depth -= 1
                if depth < 0:
                    problems.append(f"{path.relative_to(ROOT)} closes its #if DEBUG early")
                    break

    for path in sorted(list((ROOT / "App").rglob("*.swift")) + list((ROOT / "Shared").rglob("*.swift"))):
        if path in HARNESS_FILES:
            continue
        stack = []  # whether each open #if is a plain `#if DEBUG`
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            text = line.strip()
            if text.startswith("#if"):
                stack.append(text == "#if DEBUG")
            elif text.startswith("#endif") and stack:
                stack.pop()
            elif text.startswith("#else") and stack:
                # The #else of `#if DEBUG` is the release branch.
                stack[-1] = False
            elif SYMBOLS.search(line) and not text.startswith("//") and not text.startswith("///") and not any(stack):
                problems.append(f"{path.relative_to(ROOT)}:{number} names the UI-test mode outside #if DEBUG: {text}")

    if problems:
        print("The UI-test mode is not confined to debug builds:")
        for problem in problems:
            print("  " + problem)
        return 1
    print("The UI-test mode is confined to debug builds.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
