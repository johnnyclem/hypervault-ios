#!/usr/bin/env python3
"""Draws the HyperVault app icon (1024x1024) in three appearances.

    python3 scripts/make_icon.py

Writes App/Assets.xcassets/AppIcon.appiconset/{icon-light,icon-dark,icon-tinted}.png.
The mark is the web app's: a white "H" on a violet-to-cyan gradient.
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersample for clean edges
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "Assets.xcassets", "AppIcon.appiconset")

VIOLET = np.array([0x8B, 0x5C, 0xF6], dtype=np.float32)
BLUE = np.array([0x3B, 0x82, 0xF6], dtype=np.float32)
CYAN = np.array([0x22, 0xD3, 0xEE], dtype=np.float32)


def gradient(size, stops):
    """A diagonal gradient across `stops` (list of (t, rgb))."""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (xs + ys) / (2.0 * (size - 1))
    out = np.zeros((size, size, 3), dtype=np.float32)
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        mask = (t >= t0) & (t <= t1)
        k = ((t - t0) / (t1 - t0))[..., None]
        out = np.where(mask[..., None], c0 + (c1 - c0) * k, out)
    return out


def mark_mask(size):
    """The H, as an antialiased 0-1 mask."""
    s = size * SS
    img = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(img)
    u = s / 1024.0
    r = 18 * u  # softened corners
    # Two stems and the crossbar, proportions from the web icon.
    d.rounded_rectangle([226 * u, 140 * u, 342 * u, 884 * u], r, fill=255)
    d.rounded_rectangle([682 * u, 140 * u, 798 * u, 884 * u], r, fill=255)
    d.rounded_rectangle([226 * u, 456 * u, 798 * u, 570 * u], r, fill=255)
    return img.resize((size, size), Image.LANCZOS)


def save(arr, name):
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    img.save(os.path.join(OUT, name), "PNG")


def main():
    os.makedirs(OUT, exist_ok=True)
    mask = np.asarray(mark_mask(SIZE), dtype=np.float32)[..., None] / 255.0
    shadow = np.asarray(
        mark_mask(SIZE).filter(ImageFilter.GaussianBlur(28)), dtype=np.float32
    )[..., None] / 255.0

    brand = gradient(SIZE, [(0.0, VIOLET), (0.5, BLUE), (1.0, CYAN)])
    # A soft light from the top-left makes the surface feel less flat.
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    glow = np.exp(-(((xs - 220) ** 2 + (ys - 160) ** 2) / (2 * 380.0**2)))[..., None]
    light = brand + glow * 38.0

    # Light appearance: gradient field, white H with a gentle drop shadow.
    shadowed = light * (1 - 0.28 * np.roll(shadow, 14, axis=0))
    save(shadowed * (1 - mask) + 255.0 * mask, "icon-light.png")

    # Dark appearance: near-black field, the H carries the gradient.
    ink = np.zeros((SIZE, SIZE, 3), dtype=np.float32) + np.array([0x0B, 0x0F, 0x14], dtype=np.float32)
    ink = ink + glow * 14.0
    save(ink * (1 - mask) + brand * mask, "icon-dark.png")

    # Tinted appearance: grayscale, the system colours it.
    gray = np.zeros((SIZE, SIZE, 3), dtype=np.float32) + 12.0
    save(gray * (1 - mask) + 235.0 * mask, "icon-tinted.png")


if __name__ == "__main__":
    main()
