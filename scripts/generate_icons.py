#!/usr/bin/env python3
"""Regenerate every Snap2Sell raster icon from the vector masters.

Masters (hand-authored, the existing brand design — quality rebuild only):
  assets/logo.svg   in-app logo composition
  assets/icon.svg   app icon composition (same design)

Every raster below is rendered by cairosvg at its exact target size.
Never upscale a smaller raster. Requires: cairosvg, Pillow
(pip install cairosvg pillow).

Also rebuilds the store package icon-512.png and feature-graphic.png
when the store package folder is present.
"""
import json
import re
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
LOGO = ROOT / "assets" / "logo.svg"
ICON = ROOT / "assets" / "icon.svg"
STORE = (Path.home() / "workspace" / "your_files" / "businesses" /
         "snap2sell" / "documents" / "store-package")

CREAM = (242, 236, 222, 255)


def render(svg_path: Path, out: Path, size: int) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(url=str(svg_path), write_to=str(out),
                     output_width=size, output_height=size)
    print(f"{out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}  {size}x{size}")


def maskable_svg(size_fraction: float = 0.80) -> Path:
    """Icon composition padded inside a cream safe zone for maskable use."""
    text = LOGO.read_text()
    inner = text[text.index(">", text.index("<svg")) + 1:text.rindex("</svg>")]
    pad = (1 - size_fraction) / 2 * 1024
    side = size_fraction * 1024
    tmp = Path("/tmp/icon_maskable.svg")
    tmp.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        f'width="1024" height="1024">'
        f'<rect width="1024" height="1024" fill="#F2ECDE"/>'
        f'<svg x="{pad:.0f}" y="{pad:.0f}" width="{side:.0f}" height="{side:.0f}" '
        f'viewBox="0 0 1024 1024">{inner}</svg></svg>')
    return tmp


def main() -> None:
    # In-app logo
    render(LOGO, ROOT / "assets" / "logo.png", 1024)

    # Android legacy + adaptive foreground (same composition; the adaptive
    # background colour @color/ic_launcher_background is already #F2ECDE,
    # matching the design's cream, so no double background appears)
    android = {"mdpi": (48, 108), "hdpi": (72, 162), "xhdpi": (96, 216),
               "xxhdpi": (144, 324), "xxxhdpi": (192, 432)}
    for density, (launcher, foreground) in android.items():
        base = ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}"
        render(ICON, base / "ic_launcher.png", launcher)
        render(ICON, base / "ic_launcher_foreground.png", foreground)

    # iOS — every entry declared in Contents.json, at its exact pixel size
    appicon = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents = json.loads((appicon / "Contents.json").read_text())
    done = set()
    for img in contents["images"]:
        fname = img["filename"]
        if fname in done:
            continue
        done.add(fname)
        points = float(img["size"].split("x")[0])
        scale = float(img["scale"].rstrip("x"))
        render(ICON, appicon / fname, round(points * scale))

    # Web
    render(ICON, ROOT / "web" / "icons" / "Icon-192.png", 192)
    render(ICON, ROOT / "web" / "icons" / "Icon-512.png", 512)
    mask = maskable_svg()
    render(mask, ROOT / "web" / "icons" / "Icon-maskable-192.png", 192)
    render(mask, ROOT / "web" / "icons" / "Icon-maskable-512.png", 512)
    render(ICON, ROOT / "web" / "favicon.png", 16)  # matches existing 16x16

    if STORE.exists():
        render(ICON, STORE / "icon-512.png", 512)
        build_feature_graphic(STORE / "feature-graphic.png")


def build_feature_graphic(out: Path) -> None:
    """1024x500 Play feature graphic: same layout as before — circular logo
    badge on a deep-navy gradient, name + tagline on the right — rebuilt
    with the crisp icon."""
    W, H = 1024, 500
    top, bottom = (13, 33, 80), (6, 16, 44)
    bg = Image.new("RGB", (W, H))
    for y in range(H):
        t = y / (H - 1)
        bg.paste(tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
                 (0, y, W, y + 1))

    # Circular badge from the crisp 1024 icon (its off-white circle)
    icon = Image.open(ROOT / "assets" / "logo.png").convert("RGB")
    badge_d = 344
    badge = icon.resize((badge_d, badge_d), Image.LANCZOS)
    mask = Image.new("L", (badge_d, badge_d), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, badge_d, badge_d), fill=255)
    bx, by = 28, (H - badge_d) // 2
    ring = Image.new("RGBA", (badge_d + 8, badge_d + 8), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((0, 0, badge_d + 7, badge_d + 7),
                                 outline=(210, 220, 245, 255), width=3)
    bg.paste(ring, (bx - 4, by - 4), ring)
    bg.paste(badge, (bx, by), mask)

    draw = ImageDraw.Draw(bg)
    bold = "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"
    reg = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
    draw.text((424, 148), "Snap2Sell", font=ImageFont.truetype(bold, 96),
              fill=(255, 255, 255))
    draw.text((428, 272), "Snap it. Sell it. Done.",
              font=ImageFont.truetype(bold, 47), fill=(74, 222, 128))
    draw.text((428, 338), "AI drafts your listing from a photo",
              font=ImageFont.truetype(reg, 35), fill=(169, 184, 232))
    bg.save(out)
    print(f"{out}  1024x500")


if __name__ == "__main__":
    sys.exit(main())
