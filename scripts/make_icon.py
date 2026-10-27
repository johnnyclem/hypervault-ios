#!/usr/bin/env python3
"""Cuts the HyperVault app icon (1024x1024) from its artwork.

    python3 scripts/make_icon.py

Reads docs/app-icon-source.png and writes App/Assets.xcassets/AppIcon.appiconset/icon-light.png.

The artwork is a rounded tile on a background of its own, with a soft shadow. The App Store wants a square that
reaches every edge, with no alpha channel and no rounded corners of its own (the system rounds it), so the icon is
the inside of the tile: a square taken far enough in from the corners that none of the tile's rounded edge, the
shadow or the background is in it, centred on the drawing. Run on the file as it is, it gives the same icon every time.
"""
import os
from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..")
SOURCE = os.path.join(ROOT, "docs", "app-icon-source.png")
OUT = os.path.join(ROOT, "App", "Assets.xcassets", "AppIcon.appiconset", "icon-light.png")

# Left, top, right, bottom in the 1408-pixel artwork. The tile runs from about 205 to 1200 across and 157 to 1215
# down with corners of about 200 pixels; this square is 880 on a side and its corners stay inside those curves.
BOX = (267, 232, 1147, 1112)
SIZE = 1024


def main():
    art = Image.open(SOURCE).convert("RGB")
    assert art.size == (1408, 1408), f"the box is measured on a 1408-pixel square, this is {art.size}"
    icon = art.crop(BOX).resize((SIZE, SIZE), Image.LANCZOS)
    icon.save(OUT, optimize=True)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({icon.mode}, {SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
