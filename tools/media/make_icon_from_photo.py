#!/usr/bin/env python3
"""Launcher icons and store icon of Full Relax from the product owner's photo.

Source: medias-bruts/icone/full-relax-source.jpg (1536 x 2752, given on 29 Oct 2026).
Square crop « A »: lightning on the left, wet leaves on the right, trees behind.

Outputs (repository root relative):
- app/android/app/src/main/res/mipmap-<density>/ic_launcher_background.png  photo, full 108 dp layer
- .../ic_launcher_foreground.png   transparent (the photo is the background layer)
- .../ic_launcher_monochrome.png   white bolt and leaf (Android 13+ themed icons)
- .../ic_launcher.png              legacy icon (Android 7), rounded square
- app/assets/brand/logo_512.png, logo_1024.png  store icon, opaque, square

Usage: python3 tools/media/make_icon_from_photo.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / 'medias-bruts' / 'icone' / 'full-relax-source.jpg'
RES = REPO / 'app' / 'android' / 'app' / 'src' / 'main' / 'res'
BRAND = REPO / 'app' / 'assets' / 'brand'

DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}

# Crop « A » (validated on screen at 48, 64 and 96 px): what the user sees.
CROP_A = (150, 420, 1250, 1520)
# Adaptive layer: 108 dp of which only the central 72 dp (2/3) are ever shown. Its centre sits a
# little left of crop A so the lightning is not cut by a round mask; visible part ≈ 853 px wide.
CENTER = (640, 980)
LAYER_SIDE = 1280


def layer_box(img):
    side = min(img.width, img.height, LAYER_SIDE)
    cx = min(max(CENTER[0], side // 2), img.width - side // 2)
    cy = min(max(CENTER[1], side // 2), img.height - side // 2)
    return (cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side)


def rounded_mask(size, radius_ratio=0.22, scale=4):
    big = Image.new('L', (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1), radius=int(size * scale * radius_ratio), fill=255)
    return big.resize((size, size), Image.LANCZOS)


def monochrome(size, scale=4):
    """White lightning bolt and one leaf, inside the 66 dp safe circle of a 108 dp layer."""
    s = size * scale / 108.0
    img = Image.new('L', (size * scale, size * scale), 0)
    d = ImageDraw.Draw(img)
    bolt = [(52, 29), (42, 57), (51, 57), (45, 81), (65, 48), (55, 48), (62, 29)]
    d.polygon([(x * s, y * s) for x, y in bolt], fill=255)
    # Leaf: a lens shape tilted towards the top right, with a cut for its midrib.
    import math
    pts = []
    for i in range(0, 181, 6):
        t = math.radians(i)
        pts.append((math.cos(t) * 10, -math.sin(t) * 4.5))
    for i in range(180, 361, 6):
        t = math.radians(i)
        pts.append((math.cos(t) * 10, -math.sin(t) * 4.5))
    ang = math.radians(-40)
    cx, cy = 67, 38
    leaf = [(cx + x * math.cos(ang) - y * math.sin(ang), cy + x * math.sin(ang) + y * math.cos(ang)) for x, y in pts]
    d.polygon([(x * s, y * s) for x, y in leaf], fill=255)
    d.line([((cx - 8.5 * math.cos(ang)) * s, (cy - 8.5 * math.sin(ang)) * s),
            ((cx + 8.5 * math.cos(ang)) * s, (cy + 8.5 * math.sin(ang)) * s)], fill=0, width=max(1, int(1.2 * s)))
    alpha = img.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def main():
    src = Image.open(SRC).convert('RGB')
    layer = src.crop(layer_box(src))
    square = src.crop(CROP_A)
    for name, k in DENSITIES.items():
        folder = RES / f'mipmap-{name}'
        folder.mkdir(parents=True, exist_ok=True)
        full = round(108 * k)
        layer.resize((full, full), Image.LANCZOS).save(folder / 'ic_launcher_background.png', optimize=True)
        Image.new('RGBA', (full, full), (0, 0, 0, 0)).save(folder / 'ic_launcher_foreground.png', optimize=True)
        monochrome(full).save(folder / 'ic_launcher_monochrome.png', optimize=True)
        legacy = round(48 * k)
        icon = square.resize((legacy, legacy), Image.LANCZOS).convert('RGBA')
        icon.putalpha(rounded_mask(legacy))
        icon.save(folder / 'ic_launcher.png', optimize=True)
    for px in (512, 1024):
        square.resize((px, px), Image.LANCZOS).save(BRAND / f'logo_{px}.png', optimize=True)
    print('layer box', layer_box(src), 'crop', CROP_A)


if __name__ == '__main__':
    main()
