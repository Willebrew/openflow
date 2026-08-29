#!/usr/bin/env python3
"""Composite the README lockup onto the live hero, fading to white.

No grey bar, no label pills, no glow orbs. Finder still draws black
"openflow" / "Applications", so sparkle stays a thin top band and the
field is white well above the icon row.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
HERO = ROOT / "release/dmg/hero-crop.png"
LOGO = ROOT / "docs/openflow_logo.png"
OUT = ROOT / "release/dmg/background.png"

# 540x360 Finder window at 2x. Icon centers match build-first-install-dmg.sh.
ICON_ROW_Y = 360
# Previous sparkle-to-white lockup was a 268px hero; keep a header mark.
LOGO_WIDTH = 156
# Sparkle in the top quarter; white before the icon row at ICON_ROW_Y.
FADE_START_RATIO = 0.05
FADE_END_RATIO = 0.22


def knockout_black(image: Image.Image) -> Image.Image:
    """Keep the white README lockup; drop the black field."""
    src = image.convert("RGBA")
    pixels = src.load()
    width, height = src.size
    for pos_y in range(height):
        for pos_x in range(width):
            red, green, blue, alpha = pixels[pos_x, pos_y]
            luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            if luma < 18 or alpha < 8:
                pixels[pos_x, pos_y] = (255, 255, 255, 0)
            else:
                pixels[pos_x, pos_y] = (
                    255,
                    255,
                    255,
                    int(min(255, luma * (alpha / 255.0))),
                )
    return src


def fade_to_white(canvas: Image.Image) -> Image.Image:
    """Keep sparkle in a thin top band; wash to white well above the icons."""
    width, height = canvas.size
    fade_start = int(height * FADE_START_RATIO)
    fade_end = int(height * FADE_END_RATIO)
    if fade_end >= ICON_ROW_Y:
        raise SystemExit("fade must complete above the icon row")
    fade_span = max(1, fade_end - fade_start)

    white = Image.new("RGBA", (width, height), (255, 255, 255, 255))
    mask = Image.new("L", (width, height), 0)
    mask_draw = ImageDraw.Draw(mask)
    for pos_y in range(height):
        if pos_y <= fade_start:
            cover = 0
        elif pos_y >= fade_end:
            cover = 255
        else:
            t = (pos_y - fade_start) / fade_span
            t = t * t * (3.0 - 2.0 * t)
            cover = int(255 * t)
        mask_draw.line([(0, pos_y), (width, pos_y)], fill=cover)
    mask = mask.filter(ImageFilter.GaussianBlur(10))
    return Image.composite(white, canvas, mask)


def main() -> None:
    if not HERO.is_file():
        raise SystemExit(f"missing live hero crop: {HERO}")
    if not LOGO.is_file():
        raise SystemExit(f"missing README logo: {LOGO}")

    canvas = Image.open(HERO).convert("RGBA")
    if canvas.size != (1080, 720):
        raise SystemExit(f"hero crop must be 1080x720, got {canvas.size}")

    canvas = fade_to_white(canvas)

    logo = knockout_black(Image.open(LOGO))
    target_width = LOGO_WIDTH
    target_height = max(1, round(logo.height * (target_width / logo.width)))
    logo = logo.resize((target_width, target_height), Image.Resampling.LANCZOS)
    canvas.paste(logo, (36, 24), logo)

    rgb = canvas.convert("RGB")
    rgb.save(OUT, "PNG")
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
