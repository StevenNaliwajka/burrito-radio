#!/usr/bin/env python3
"""Offline preview of the radio model: draws model.json (tools/preview/export.lua) with a
tiny numpy rasterizer, using the same texture draw-ops the game runs, so the look can be
checked against the product photos without starting GMod.

    lua tools/preview/export.lua > model.json      (or the docker one-liner in docs)
    python3 tools/preview/render.py model.json out_dir [--size 900]

Writes front.png, three_quarter.png, back.png, side.png and sheet.png (all four).
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT_PATHS = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"]


def font(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            return ImageFont.truetype(p, int(size))
    return ImageFont.load_default()


class LCG:
    """The same generator as cl_model.lua's speckle op (so noise matches the game)."""
    def __init__(self, seed):
        self.s = seed % 2147483647 or 1

    def next(self):
        self.s = (self.s * 16807) % 2147483647
        return self.s / 2147483647


def draw_texture(spec):
    w, h, ops = spec
    im = Image.new("RGB", (int(w), int(h)))
    d = ImageDraw.Draw(im)
    for op in ops:
        k = op[0]
        if k == "fill":
            d.rectangle([0, 0, w, h], fill=tuple(op[1]))
        elif k == "rect":
            _, x, y, ww, hh, c = op
            d.rectangle([x, y, x + ww - 1, y + hh - 1], fill=tuple(c))
        elif k == "rrect":
            _, x, y, ww, hh, r, c = op
            d.rounded_rectangle([x, y, x + ww - 1, y + hh - 1], radius=r, fill=tuple(c))
        elif k == "ellipse":
            _, cx, cy, rx, ry, c = op
            d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=tuple(c))
        elif k == "ring":
            _, cx, cy, r0, r1, c = op
            d.ellipse([cx - r1, cy - r1, cx + r1, cy + r1], outline=tuple(c), width=max(1, int(round(r1 - r0))))
        elif k == "poly":
            pts = op[1]
            d.polygon([(pts[i], pts[i + 1]) for i in range(0, len(pts), 2)], fill=tuple(op[2]))
        elif k == "speckle":
            _, seed, count, size, ca, cb = op
            g = LCG(seed)
            for _ in range(int(count)):
                x, y, t = g.next() * w, g.next() * h, g.next()
                c = tuple(int(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))
                d.rectangle([x, y, x + size - 1, y + size - 1], fill=c)
        elif k == "dots":
            _, x, y, ww, hh, pitch, r, c = op
            row = 0
            yy = y + r
            while yy <= y + hh - r:
                xx = x + r + (pitch / 2 if row % 2 else 0)
                while xx <= x + ww - r:
                    d.ellipse([xx - r, yy - r, xx + r, yy + r], fill=tuple(c))
                    xx += pitch
                yy += pitch * 0.866
                row += 1
        elif k == "text":
            _, s, x, y, size, c, align = op[:7]
            sp = op[7] if len(op) > 7 else 0
            f = font(size)
            widths = [d.textlength(ch, font=f) for ch in s]
            total = sum(widths) + sp * (len(s) - 1)
            cx = x - total / 2 if align == 1 else x
            for ch, wch in zip(s, widths):
                d.text((cx, y), ch, fill=tuple(c), font=f, anchor="lm")
                cx += wch + sp
        elif k == "vgrad":
            _, x, y, ww, hh, ct, cb = op
            for i in range(int(hh)):
                t = i / max(1, hh - 1)
                c = tuple(int(ct[j] + (cb[j] - ct[j]) * t) for j in range(3))
                d.line([(x, y + i), (x + ww - 1, y + i)], fill=c)
        else:
            raise ValueError("unknown op " + k)
    return np.asarray(im).astype(np.float32) / 255.0


def look(eye, target, fov, w, h):
    eye, target = np.array(eye, float), np.array(target, float)
    f = target - eye
    f /= np.linalg.norm(f)
    up = np.array([0, 0, 1.0])
    r = np.cross(f, up)
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    fl = (w / 2) / math.tan(math.radians(fov) / 2)

    def proj(p):
        q = p - eye
        z = q @ f
        return np.stack([w / 2 + (q @ r) * fl / z, h / 2 - (q @ u) * fl / z, z], axis=-1)
    return proj


def render(model, tex, eye, target, w, h, fov=30, bg=(0.96, 0.96, 0.97)):
    ss = 2
    W, H = w * ss, h * ss
    proj = look(eye, target, fov, W, H)
    color = np.empty((H, W, 3), np.float32)
    color[:] = bg
    depth = np.full((H, W), np.inf, np.float32)
    for mat, flat in model["parts"].items():
        t = tex[mat]
        th, tw = t.shape[:2]
        v = np.array(flat, np.float64).reshape(-1, 3, 6)
        sp = proj(v[..., :3])
        for i in range(v.shape[0]):
            p = sp[i]
            if (p[:, 2] <= 0.01).any():
                continue
            x0, x1 = int(max(0, math.floor(p[:, 0].min()))), int(min(W - 1, math.ceil(p[:, 0].max())))
            y0, y1 = int(max(0, math.floor(p[:, 1].min()))), int(min(H - 1, math.ceil(p[:, 1].max())))
            if x0 > x1 or y0 > y1:
                continue
            xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
            (ax, ay), (bx, by), (cx, cy) = p[0, :2], p[1, :2], p[2, :2]
            den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(den) < 1e-12:
                continue
            l0 = ((by - cy) * (xs - cx) + (cx - bx) * (ys - cy)) / den
            l1 = ((cy - ay) * (xs - cx) + (ax - cx) * (ys - cy)) / den
            l2 = 1 - l0 - l1
            inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
            if not inside.any():
                continue
            iz = l0 / p[0, 2] + l1 / p[1, 2] + l2 / p[2, 2]
            z = 1 / iz
            sub = depth[y0:y1 + 1, x0:x1 + 1]
            m = inside & (z < sub)
            if not m.any():
                continue
            a = v[i]
            pu = (l0 * a[0, 3] / p[0, 2] + l1 * a[1, 3] / p[1, 2] + l2 * a[2, 3] / p[2, 2]) * z
            pv = (l0 * a[0, 4] / p[0, 2] + l1 * a[1, 4] / p[1, 2] + l2 * a[2, 4] / p[2, 2]) * z
            sh = l0 * a[0, 5] + l1 * a[1, 5] + l2 * a[2, 5]
            tx = np.mod(np.floor(pu * tw).astype(int), tw)
            ty = np.mod(np.floor(pv * th).astype(int), th)
            c = t[ty, tx] * sh[..., None]
            sub[m] = z[m]
            color[y0:y1 + 1, x0:x1 + 1][m] = c[m]
    img = Image.fromarray((np.clip(color, 0, 1) * 255).astype(np.uint8))
    return img.resize((w, h), Image.LANCZOS)


def display_overlay(model):
    """What the game draws on the display window (cl_init.lua's 3D2D): elapsed time."""
    return None


def main():
    src, out = sys.argv[1], sys.argv[2]
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 700
    os.makedirs(out, exist_ok=True)
    model = json.load(open(src))
    tex = {k: draw_texture(v) for k, v in model["textures"].items()}
    for name, t in tex.items():
        if name in ("front", "back", "button"):
            Image.fromarray((t * 255).astype(np.uint8)).save(os.path.join(out, "tex_%s.png" % name))
    tgt = (0, 0, 1.75)
    views = {
        "front": ((22, 0, 2.2), tgt),
        "three_quarter": ((15, 13, 8.5), (0, 0, 2.2)),
        "back": ((-22, 0, 2.6), tgt),
        "side": ((0, 24, 2.0), tgt),
    }
    imgs = []
    for name, (eye, target) in views.items():
        im = render(model, tex, eye, target, size, size)
        im.save(os.path.join(out, name + ".png"))
        imgs.append(im)
    sheet = Image.new("RGB", (size * 2, size * 2), "white")
    for i, im in enumerate(imgs):
        sheet.paste(im, ((i % 2) * size, (i // 2) * size))
    sheet.save(os.path.join(out, "sheet.png"))
    print("wrote", out)


if __name__ == "__main__":
    main()
