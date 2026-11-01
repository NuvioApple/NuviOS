#!/usr/bin/env python3
"""Generate the tvOS layered app icon (AppIcon-tvOS.brandassets).

Three flat layers, no baked shadow/glow: tvOS adds parallax, specular and the
focus shadow itself. Back = purple gradient, Middle = outer white ring,
Front = inner ring. Re-run to regenerate the catalog.
"""
import json
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "NuviOS/Assets.xcassets/AppIcon-tvOS.brandassets"
INFO = {"author": "xcode", "version": 1}

W, H = 2560, 1536  # largest @2x; everything else is downscaled from this


def rounded_triangle(size, center, radius_out, corner):
    """Antialiased mask of a right-pointing equilateral triangle, rounded corners.

    radius_out is the circumradius of the sharp hull; corner is the corner radius.
    Uses the exact signed distance to the inset triangle, so edges stay smooth.
    """
    w, h = size
    R = float(radius_out)
    k = (R / 2 - corner) / (R / 2)  # shrink so rounding lands back on the hull
    pts = np.array([(R * k * math.cos(math.radians(i * 120)),
                     R * k * math.sin(math.radians(i * 120))) for i in range(3)])
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    px, py = xs - center[0], ys - center[1]
    dist = np.full((h, w), np.inf, dtype=np.float32)
    inside = np.ones((h, w), dtype=bool)
    for i in range(3):
        a, b = pts[i], pts[(i + 1) % 3]
        e = b - a
        t = np.clip(((px - a[0]) * e[0] + (py - a[1]) * e[1]) / (e @ e), 0, 1)
        dx, dy = px - (a[0] + t * e[0]), py - (a[1] + t * e[1])
        dist = np.minimum(dist, np.hypot(dx, dy))
        cross = e[0] * (py - a[1]) - e[1] * (px - a[0])
        inside &= cross >= 0
    sd = np.where(inside, -dist, dist)
    alpha = np.clip(corner - sd + 0.5, 0, 1)
    return Image.fromarray((alpha * 255).astype(np.uint8))


def back_layer():
    top, bottom = (196, 38, 255), (92, 10, 245)
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        t = y / (H - 1)
        row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(W):
            px[x, y] = row
    return img.convert("RGBA")


def ring_layer(color, outer_R, outer_corner, hole_R, hole_corner, center, hole_center):
    mask = rounded_triangle((W, H), center, outer_R, outer_corner)
    hole = rounded_triangle((W, H), hole_center, hole_R, hole_corner)
    alpha = Image.composite(Image.new("L", (W, H), 0), mask, hole)
    layer = Image.new("RGBA", (W, H), color + (0,))
    layer.putalpha(alpha)
    return layer


def build_layers():
    # A right-pointing triangle's bbox centre sits R/4 right of its centroid;
    # offset so the mark is centred, plus a little optical nudge right.
    c = (W / 2 - 620 / 4 + 25, H / 2)
    back = back_layer()
    middle = ring_layer((255, 255, 255), 620, 130, 490, 95, c, c)
    front = ring_layer((238, 230, 255), 455, 80, 265, 55, c, c)
    return {"Back": back, "Middle": middle, "Front": front}


def write_stack(name, size, layers):
    sw, sh = size
    stack = BRAND / f"{name}.imagestack"
    order = ["Front", "Middle", "Back"]
    (stack).mkdir(parents=True)
    (stack / "Contents.json").write_text(json.dumps(
        {"layers": [{"filename": f"{n}.imagestacklayer"} for n in order], "info": INFO}, indent=2))
    for n in order:
        layer_dir = stack / f"{n}.imagestacklayer"
        imgset = layer_dir / "Content.imageset"
        imgset.mkdir(parents=True)
        (layer_dir / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2))
        images = []
        for scale in (1, 2):
            fn = f"{n.lower()}{'' if scale == 1 else '@2x'}.png"
            img = layers[n].resize((sw * scale, sh * scale), Image.LANCZOS)
            if n == "Back":
                img = img.convert("RGB")  # bottom layer must be opaque
            img.save(imgset / fn)
            images.append({"idiom": "tv", "filename": fn, "scale": f"{scale}x"})
        (imgset / "Contents.json").write_text(json.dumps({"images": images, "info": INFO}, indent=2))


def main():
    if BRAND.exists():
        shutil.rmtree(BRAND)
    BRAND.mkdir(parents=True)
    layers = build_layers()
    write_stack("App Icon - Large", (1280, 768), layers)
    small = {k: v.resize((800, 480), Image.LANCZOS) for k, v in layers.items()}
    write_stack("App Icon - Small", (400, 240), small)
    (BRAND / "Contents.json").write_text(json.dumps({
        "assets": [
            {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        ],
        "info": INFO,
    }, indent=2))
    # Flat preview for eyeballing
    prev = layers["Back"].copy()
    for n in ("Middle", "Front"):
        prev = Image.alpha_composite(prev, layers[n])
    prev.convert("RGB").resize((1280, 768), Image.LANCZOS).save(Path(__file__).parent / "tvos_icon_preview.png")
    print("wrote", BRAND)


if __name__ == "__main__":
    main()
