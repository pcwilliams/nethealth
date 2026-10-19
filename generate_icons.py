#!/usr/bin/env python3
"""Generate the NetHealth macOS app icon.

Modelled on the app's actual look: the deep dark ambient background (the same
vertical gradient + top glow as ContentView.AmbientBackground) overlaid with the
flowing **aurora latency ribbons** from AuroraGraphView — three translucent
gradient bands (green / teal / amber, the app's health tints) each with a blurred
glow stroke, a crisp bright trace, and a glowing leading-edge dot.

Full-bleed 1024×1024 RGB, supersampled for clean anti-aliasing — matching the
suite convention (see spectrum/generate_icons.py). Emits every macOS icon size
and rewrites the AppIcon Contents.json to reference them.
"""

import json
import os
import math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ICONSET = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "NetHealth", "Assets.xcassets", "AppIcon.appiconset")

SIZE = 1024
SUPER = 3
SS = SIZE * SUPER

# --- Palette (straight from the app) ---------------------------------------
# ContentView.AmbientBackground vertical gradient + Models.HealthState tints.
BG_TOP = (10, 13, 23)     # Color(0.04, 0.05, 0.09)
BG_MID = (15, 18, 31)     # Color(0.06, 0.07, 0.12), faintly tinted
BG_BOT = (0, 0, 0)

GREEN = (77, 242, 179)    # excellent
TEAL  = (89, 217, 242)    # good
AMBER = (250, 209, 89)    # fair


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def vertical_gradient():
    """The app's top→mid→black ambient gradient, as a full RGBA layer."""
    col = Image.new("RGB", (1, SS))
    for y in range(SS):
        t = y / (SS - 1)
        if t < 0.45:
            c = lerp(BG_TOP, BG_MID, t / 0.45)
        else:
            c = lerp(BG_MID, BG_BOT, (t - 0.45) / 0.55)
        col.putpixel((0, y), c)
    return col.resize((SS, SS)).convert("RGBA")


def top_glow(color, cx_frac=0.5, cy_frac=0.08, radius_frac=0.80, max_alpha=80):
    """Soft radial bloom near the top — the app's RadialGradient health tint."""
    layer = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = SS * cx_frac, SS * cy_frac
    R = SS * radius_frac
    steps = 320
    for i in range(steps, 0, -1):
        r = R * i / steps
        a = int(max_alpha * (1 - i / steps) ** 2.0)
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=(color[0], color[1], color[2], a))
    return layer


def ribbon_points(baseline, amp, freq, phase, tilt):
    """A flowing latency trace across the full width (y grows downward)."""
    pts = []
    N = 480
    left, right = -SS * 0.02, SS * 1.02   # bleed slightly past both edges
    for i in range(N + 1):
        t = i / N
        x = left + t * (right - left)
        wave = (math.sin(2 * math.pi * freq * t + phase) * amp
                + math.sin(2 * math.pi * freq * 2.1 * t + phase * 1.7) * amp * 0.38
                + math.sin(2 * math.pi * freq * 0.5 * t + phase * 0.5) * amp * 0.25)
        y = baseline + wave - tilt * t
        pts.append((x, y))
    return pts


def fill_alpha_gradient(tint):
    """Tint with vertical alpha falloff — strong up top, fading to the floor
    (mirrors the ribbon's .opacity(0.55) → .opacity(0.06) fill)."""
    col = Image.new("RGBA", (1, SS))
    for y in range(SS):
        t = y / (SS - 1)
        a = int(max(0, 140 * (1 - t)) ** 1.0)
        a = int(140 * max(0.0, 1 - t) ** 1.4)
        col.putpixel((0, y), (tint[0], tint[1], tint[2], a))
    return col.resize((SS, SS))


def draw_ribbon(base, pts, tint):
    """One aurora band: gradient fill, blurred glow, crisp trace, leading dot."""
    # --- translucent gradient fill below the curve --------------------------
    area = list(pts) + [(pts[-1][0], SS), (pts[0][0], SS)]
    mask = Image.new("L", (SS, SS), 0)
    ImageDraw.Draw(mask).polygon(area, fill=255)
    grad = fill_alpha_gradient(tint)
    grad.putalpha(ImageChops.multiply(grad.split()[3], mask))
    base.alpha_composite(grad)

    crisp_w = int(SS * 0.0090)
    glow_w = int(SS * 0.020)
    blur_r = int(SS * 0.018)

    # --- blurred glow underlay ---------------------------------------------
    glow = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.line(pts, fill=(tint[0], tint[1], tint[2], 200), width=glow_w, joint="curve")
    glow = glow.filter(ImageFilter.GaussianBlur(blur_r))
    base.alpha_composite(glow)

    # --- crisp bright trace -------------------------------------------------
    d = ImageDraw.Draw(base)
    d.line(pts, fill=(tint[0], tint[1], tint[2], 255), width=crisp_w, joint="curve")
    r = crisp_w / 2
    for (px, py) in (pts[0], pts[-1]):
        d.ellipse([px - r, py - r, px + r, py + r], fill=(tint[0], tint[1], tint[2], 255))

    # --- glowing leading-edge dot (newest reading) -------------------------
    # Anchor it just inside the right edge so it reads as "now".
    head = next((p for p in reversed(pts) if p[0] <= SS * 0.93), pts[-1])
    dot_r = int(SS * 0.017)
    bright = tuple(min(255, c + 45) for c in tint)
    halo = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse(
        [head[0] - dot_r * 1.8, head[1] - dot_r * 1.8,
         head[0] + dot_r * 1.8, head[1] + dot_r * 1.8],
        fill=(tint[0], tint[1], tint[2], 200))
    halo = halo.filter(ImageFilter.GaussianBlur(int(SS * 0.012)))
    base.alpha_composite(halo)
    ImageDraw.Draw(base).ellipse(
        [head[0] - dot_r, head[1] - dot_r, head[0] + dot_r, head[1] + dot_r],
        fill=(bright[0], bright[1], bright[2], 255))


def faint_grid(base):
    """Whisper-faint horizontal scale lines + vertical time guides, like the app."""
    d = ImageDraw.Draw(base)
    for frac in (0.30, 0.475, 0.65, 0.825):
        y = int(SS * frac)
        d.line([(0, y), (SS, y)], fill=(255, 255, 255, 12), width=max(1, SS // 1024))
    for frac in (0.28, 0.52, 0.76):
        x = int(SS * frac)
        d.line([(x, 0), (x, SS)], fill=(255, 255, 255, 9), width=max(1, SS // 1024))


def vignette():
    """Subtle darkening toward the edges for depth."""
    layer = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    steps = 240
    for i in range(steps):
        t = i / steps
        inset = int(SS * 0.5 * t)
        a = int(70 * (t ** 2.2))
        d.rectangle([inset, inset, SS - inset, SS - inset], outline=(0, 0, 0, a),
                    width=max(1, SS // 256))
    return layer.filter(ImageFilter.GaussianBlur(SS // 80))


def render_master():
    base = Image.new("RGBA", (SS, SS), (0, 0, 0, 255))
    base.alpha_composite(vertical_gradient())
    # Two stacked top glows (teal then green) — the calm, healthy ambient bloom.
    base.alpha_composite(top_glow(TEAL, cy_frac=0.06, radius_frac=0.85, max_alpha=70))
    base.alpha_composite(top_glow(GREEN, cx_frac=0.34, cy_frac=0.16, radius_frac=0.5, max_alpha=45))
    faint_grid(base)

    # Three ribbons. Higher latency sits higher (y = h − rtt/scale·h), so amber
    # rides up top, green calm near the floor. Draw back→front (green on top).
    draw_ribbon(base, ribbon_points(SS * 0.40, SS * 0.060, 2.3, 0.6, SS * 0.02), AMBER)
    draw_ribbon(base, ribbon_points(SS * 0.55, SS * 0.045, 1.7, 2.1, SS * 0.015), TEAL)
    draw_ribbon(base, ribbon_points(SS * 0.69, SS * 0.030, 1.4, 4.2, -SS * 0.01), GREEN)

    base.alpha_composite(vignette())
    return base.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


# macOS icon slots: (size string, scale) -> pixel dimension + filename
MAC_SLOTS = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]


def main():
    master = render_master()
    master.save(f"{ICONSET}/icon_1024.png", "PNG")
    print(f"Saved master icon_1024.png")

    images = []
    for size, scale, px in MAC_SLOTS:
        base_px = int(size.split("x")[0])
        fname = f"icon_{base_px}{'@2x' if scale == '2x' else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(f"{ICONSET}/{fname}", "PNG")
        images.append({"filename": fname, "idiom": "mac", "scale": scale, "size": size})
        print(f"  {fname:18s} {px}x{px}")

    with open(f"{ICONSET}/Contents.json", "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
                  f, indent=2)
    print("Wrote Contents.json")


if __name__ == "__main__":
    main()
