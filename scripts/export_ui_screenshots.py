#!/usr/bin/env python3
"""Copies the screenshots the UI tests attached to their result bundle out as plain PNG files.

    export_ui_screenshots.py <result.xcresult> <output folder>

Each journey step attaches a screenshot (see Tests/UITests/HyperVaultUITestCase.swift), so the bundle shows what the
app looked like at every step. This writes them as <output>/<TestClass>/<test name>/<number>-<step>.<ext>, in the
order they were taken, so a journey can be looked at without Xcode.

It never fails the build: if the bundle is missing or the tool is too old to export attachments, it says so and
exits 0.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".heic"}
# The sweep also attaches what it noted about each screen's layout as text; it is written out beside the screenshot.
TEXT_EXTENSIONS = {".txt"}
KEPT_TEXT = ("Layout notes", "Tree", "App UI hierarchy")


def safe(text: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")
    return cleaned[:80] or "unnamed"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 0
    bundle, output = sys.argv[1], sys.argv[2]
    if not os.path.isdir(bundle):
        print(f"No result bundle at {bundle}; nothing to export.")
        return 0

    scratch = tempfile.mkdtemp(prefix="hv-attachments-")
    try:
        result = subprocess.run(
            ["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", scratch],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print("xcresulttool could not export the attachments:", (result.stderr or result.stdout).strip()[:500])
            return 0
        manifest_path = os.path.join(scratch, "manifest.json")
        if not os.path.exists(manifest_path):
            print("The export had no manifest; nothing to copy.")
            return 0
        with open(manifest_path) as handle:
            manifest = json.load(handle)

        copied = 0
        for entry in manifest:
            test = entry.get("testIdentifier") or entry.get("testIdentifierURL") or "unknown"
            parts = [safe(piece) for piece in test.replace("()", "").split("/") if piece]
            folder = os.path.join(output, *parts) if parts else os.path.join(output, "unknown")
            attachments = sorted(entry.get("attachments", []), key=lambda item: item.get("timestamp", 0))
            number = 0
            for attachment in attachments:
                source = os.path.join(scratch, attachment.get("exportedFileName", ""))
                extension = os.path.splitext(source)[1].lower()
                if not os.path.isfile(source) or extension not in IMAGE_EXTENSIONS | TEXT_EXTENSIONS:
                    continue
                name = attachment.get("suggestedHumanReadableName") or os.path.basename(source)
                name = os.path.splitext(name)[0]
                # Of the text, keep the sweep's notes and the app's tree when a test failed; XCTest also attaches a
                # description of every query a wait made, which is noise.
                if extension in TEXT_EXTENSIONS and not name.startswith(KEPT_TEXT):
                    continue
                number += 1
                # Xcode appends an index and a UUID to the name the test gave; keep what the test said.
                name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", name)
                os.makedirs(folder, exist_ok=True)
                shutil.copyfile(source, os.path.join(folder, f"{number:02d}-{safe(name)}{extension}"))
                copied += 1
        print(f"Exported {copied} screenshots and notes to {output}.")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
