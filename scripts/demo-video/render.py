#!/usr/bin/env python3
"""Turns a raw take (record.sh) into the site's demo video, with a "Screen Studio" look.

    render.py <work dir> <out.mp4> [--poster out.jpg --poster-time s] [--stills dir t1,t2,...] [--crf N] [--fps N]

The capture already holds the wallpaper, the fake menu bar (menubar.swift) and the pet, layered by
WindowServer. On top of it, in the capture's own pixels (2x Retina): the physical notch redrawn in
black (the capture sees through it); then an eased camera crop, and a fake cursor drawn at output
resolution from the driver's log.
"""
import argparse
import bisect
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

FFMPEG = "/opt/homebrew/bin/ffmpeg" if os.path.exists("/opt/homebrew/bin/ffmpeg") else "ffmpeg"
OUT_W, OUT_H = 1920, 1200          # 16:10, like the MacBook screen drawn on the site
SRC_W, SRC_H, PX = 3024, 1964, 2   # built-in display, points x2
SCREEN_W, SCREEN_H = SRC_W / PX, SRC_H / PX
NOTCH = (663.5, 848.5, 32.0)       # x min, x max, height (points)
NOTCH_RADIUS, EAR_RADIUS = 10.0, 6.0  # NotchGeometry.bottomRadius / earRadius

ap = argparse.ArgumentParser()
ap.add_argument("work")
ap.add_argument("out")
ap.add_argument("--poster")
ap.add_argument("--poster-time", type=float, default=None)
ap.add_argument("--stills", nargs=2, metavar=("DIR", "TIMES"))
ap.add_argument("--crf", type=int, default=20)
ap.add_argument("--fps", type=int, default=60)
args = ap.parse_args()
W = args.work


def ease(u):
    """Smoother step: zero speed and acceleration at both ends, the usual camera ease."""
    u = min(1.0, max(0.0, u))
    return u * u * u * (u * (u * 6 - 15) + 10)


# ---------------------------------------------------------------- timing
meta = json.load(open(os.path.join(W, "take.mov.json")))
first = meta["first_frame_host"]
samples, marks, downs, ups = [], {}, [], []
for line in open(os.path.join(W, "cursor.jsonl")):
    d = json.loads(line)
    t = d["t"] - first
    if "mark" in d:
        marks[d["mark"]] = t
        continue
    samples.append((t, d["x"], d["y"]))
    if d["ev"] == "down":
        downs.append(t)
    elif d["ev"] == "up":
        ups.append(t)
samples.sort()
sample_t = [s[0] for s in samples]
M = marks

START = M["start"] - 0.2            # video time of the first output frame
END = M["end"] + 0.2
DURATION = END - START
FADE = 0.5


def cursor_at(t):
    i = bisect.bisect_right(sample_t, t)
    if i <= 0:
        return samples[0][1:]
    if i >= len(samples):
        return samples[-1][1:]
    (t0, x0, y0), (t1, x1, y1) = samples[i - 1], samples[i]
    u = 0 if t1 <= t0 else (t - t0) / (t1 - t0)
    return x0 + (x1 - x0) * u, y0 + (y1 - y0) * u


# ---------------------------------------------------------------- camera
# Shots: centre (points) and zoom. The crop is 16:10 and always clamped inside the screen.
WIDE = (SCREEN_W / 2, 0, 1.0)
LAPTOP_SHOT = (830, 0, 2.8)                  # the pet in the notch, the icon in the menu bar
NOTCH_SHOT = (756, 0, 2.35)                  # request panel: x 486-1026 pt
CARD_SHOT = (600, 400, 1.6)                  # floating pet + its card
MENU_SHOT = (849, 0, 1.45)                   # menu bar icon, panel and floating pet
DOCK_SHOT = (860, 0, 2.8)                    # docked pet with its hover gauges

# (start time, duration, shot): each move starts from wherever the camera is.
moves = [
    (M["start"] + 1.2, 1.3, LAPTOP_SHOT),
    (M["request1"] - 0.1, 0.9, NOTCH_SHOT),
    (M["allow1"] + 0.5, 1.0, LAPTOP_SHOT),
    (M["grab1"] - 0.05, 0.9, WIDE),
    (M["drop1"] + 0.5, 1.0, CARD_SHOT),
    (M["allow2"] + 0.3, 1.1, MENU_SHOT),
    (M["dock"] + 0.05, 1.0, DOCK_SHOT),
    (M["happy2"] + 1.3, 1.2, WIDE),
]


def clamp_cam(cx, cy, z):
    w = SCREEN_W / z
    h = w * OUT_H / OUT_W
    x = min(max(cx - w / 2, 0), SCREEN_W - w)
    y = min(max(cy - h / 2, 0), SCREEN_H - h)
    return x, y, w, h


def camera(t):
    cx, cy, z = WIDE
    cam = clamp_cam(cx, cy, z)
    for start, dur, shot in moves:
        if t < start:
            break
        u = ease((t - start) / dur)
        target = clamp_cam(*shot)
        # Interpolate the zoom geometrically and the crop's position so the motion feels even.
        x0, y0, w0, h0 = cam
        x1, y1, w1, h1 = target
        w = w0 * (w1 / w0) ** u
        # Keep the point that is fixed between both crops fixed throughout (a true zoom to a point).
        if abs(w1 - w0) > 1e-6:
            fx = (x0 * w1 - x1 * w0) / (w1 - w0)
            fy = (y0 * w1 - y1 * w0) / (w1 - w0)
            k = w / w0
            x = fx + (x0 - fx) * k
            y = fy + (y0 - fy) * k
        else:
            x = x0 + (x1 - x0) * u
            y = y0 + (y1 - y0) * u
        cam = (x, y, w, w * OUT_H / OUT_W)
    x, y, w, h = cam
    # Clamp again: the fixed point can sit outside the screen.
    x = min(max(x, 0), SCREEN_W - w)
    y = min(max(y, 0), SCREEN_H - h)
    return x, y, w, h


# ---------------------------------------------------------------- notch
BAND = 40 * PX  # rows that can hold the notch and its ears


def notch_alpha():
    """The physical notch, which the capture sees through: square top, rounded bottom corners and
    small concave ears where it meets the top edge (NotchGeometry's radii)."""
    ss = 4
    s = PX * ss
    x0, x1, h = NOTCH[0] * s, NOTCH[1] * s, NOTCH[2] * s
    r, e = NOTCH_RADIUS * s, EAR_RADIUS * s
    im = Image.new("L", (SRC_W * ss, BAND * ss), 0)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((x0, -r, x1, h), radius=r, fill=255)
    # Ears: fill the corner squares, then carve a circle out of each.
    d.rectangle((x0 - e, 0, x0, e), fill=255)
    d.rectangle((x1, 0, x1 + e, e), fill=255)
    d.ellipse((x0 - 2 * e, 0, x0, 2 * e), fill=0)
    d.ellipse((x1, 0, x1 + 2 * e, 2 * e), fill=0)
    d.rectangle((x0, 0, x1, h - r), fill=255)
    im = im.resize((SRC_W, BAND), Image.LANCZOS)
    return np.asarray(im).astype(np.float32)[..., None] / 255


NOTCH_A = notch_alpha()


def composite_top(frame):
    """The physical notch on top of everything, as on the real screen."""
    band = frame[:BAND].astype(np.float32) * (1 - NOTCH_A)
    frame[:BAND] = band.astype(np.uint8)
    return frame


# ---------------------------------------------------------------- cursor
cur_img = Image.open(os.path.join(W, "cursor.png")).convert("RGBA")
cur_meta = json.load(open(os.path.join(W, "cursor.json")))
CUR_SCALE = 1.5  # bigger than life, like Screen Studio


def press_amount(t):
    """0 at rest, 1 while the button is held, eased in and out."""
    v = 0.0
    for d in downs:
        u = next((u for u in ups if u >= d), d + 0.1)
        if t < d or t > u + 0.25:
            continue
        a = ease((t - d) / 0.08)
        b = 1 - ease((t - u) / 0.2) if t > u else 1
        v = max(v, min(a, b))
    return v


_cursor_cache = {}


def cursor_sprite(size_px):
    key = int(round(size_px * 2))
    if key not in _cursor_cache:
        h = key / 2
        w = h * cur_img.width / cur_img.height
        im = cur_img.resize((max(1, int(round(w))), max(1, int(round(h)))), Image.LANCZOS)
        # A soft extra shadow under the system one, for depth over a busy wallpaper.
        pad = int(h * 0.25)
        canvas = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
        shadow = Image.new("RGBA", im.size, (0, 0, 0, 0))
        shadow.putalpha(im.getchannel("A").point(lambda v: int(v * 0.28)))
        canvas.alpha_composite(shadow, (pad, pad + max(1, int(h * 0.03))))
        canvas = canvas.filter(ImageFilter.GaussianBlur(h * 0.05))
        canvas.alpha_composite(im, (pad, pad))
        _cursor_cache[key] = (canvas, pad)
    return _cursor_cache[key]


def draw_cursor(img, t, cam):
    x, y, w, h = cam
    s = OUT_W / w                      # output px per point
    zoom = SCREEN_W / w
    cx, cy = cursor_at(t)
    px, py = (cx - x) * s, (cy - y) * s
    base = OUT_W / SCREEN_W * CUR_SCALE * zoom ** 0.65   # output px per cursor point
    # Click: ripples behind the cursor, then the cursor shrinks a little. Drawn on their own layer:
    # ImageDraw replaces RGBA pixels instead of blending them.
    for dn in downs:
        u = (t - dn) / 0.5
        if 0 <= u <= 1:
            r = (7 + 18 * ease(u)) * base
            a = int(120 * (1 - u) ** 2)
            size = int(2 * r + 8)
            ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            c = size / 2
            ImageDraw.Draw(ring).ellipse((c - r, c - r, c + r, c + r), fill=(255, 255, 255, a // 6),
                                         outline=(255, 255, 255, a), width=max(1, int(base * 1.1)))
            _paste_clipped(img, ring, px - c, py - c)
    scale = 1 - 0.16 * press_amount(t)
    hpx = cur_meta["height"] * base * scale
    sprite, pad = cursor_sprite(hpx)
    k = hpx / cur_meta["height"]
    ox = px - pad - cur_meta["hot_x"] * k
    oy = py - pad - cur_meta["hot_y"] * k
    _paste_clipped(img, sprite, ox, oy)


def _paste_clipped(img, sprite, ox, oy):
    ox, oy = int(round(ox)), int(round(oy))
    l, t_ = max(0, -ox), max(0, -oy)
    r, b = min(sprite.width, img.width - ox), min(sprite.height, img.height - oy)
    if l >= r or t_ >= b:
        return
    img.alpha_composite(sprite.crop((l, t_, r, b)), (ox + l, oy + t_))


# ---------------------------------------------------------------- frames
def render_frame(src, t):
    frame = composite_top(src.copy())
    cam = camera(t)
    x, y, w, h = cam
    box = (x * PX, y * PX, (x + w) * PX, (y + h) * PX)
    img = Image.fromarray(frame).resize((OUT_W, OUT_H), Image.LANCZOS, box=box).convert("RGBA")
    draw_cursor(img, t, cam)
    out = img.convert("RGB")
    fade = min(1.0, (t - START) / FADE, (END - t) / FADE)
    if fade < 1:
        out = Image.fromarray((np.asarray(out).astype(np.float32) * ease(max(0.0, fade))).astype(np.uint8))
    return out


def decoder(start, fps):
    cmd = [FFMPEG, "-v", "error", "-ss", f"{max(0.0, start):.3f}", "-i", os.path.join(W, "take.mov"),
           "-vf", f"fps={fps},scale=in_color_matrix=bt709:in_range=tv", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=SRC_W * SRC_H * 3 * 2)


def read_frame(p):
    buf = p.stdout.read(SRC_W * SRC_H * 3)
    if len(buf) < SRC_W * SRC_H * 3:
        return None
    return np.frombuffer(buf, np.uint8).reshape(SRC_H, SRC_W, 3)


def grab(t):
    p = decoder(t, 60)
    f = read_frame(p)
    p.kill()
    return f


if args.stills:
    os.makedirs(args.stills[0], exist_ok=True)
    for ts in args.stills[1].split(","):
        t = START + float(ts)
        render_frame(grab(t), t).save(os.path.join(args.stills[0], f"still_{float(ts):05.2f}.png"))
    print("stills written")
    sys.exit(0)

fps = args.fps
n = int(DURATION * fps)
print(f"marks: { {k: round(v - START, 2) for k, v in M.items()} }")
print(f"rendering {n} frames, {DURATION:.1f} s at {fps} fps")
dec = decoder(START, fps)
enc = subprocess.Popen([
    FFMPEG, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT_W}x{OUT_H}", "-r", str(fps), "-i", "-",
    "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
    "-c:v", "libx264", "-preset", "slow", "-crf", str(args.crf), "-profile:v", "high", "-tune", "animation",
    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
    "-movflags", "+faststart", "-an", args.out], stdin=subprocess.PIPE)
poster_t = args.poster_time
last = None
for i in range(n):
    src = read_frame(dec)
    src = last if src is None else src
    last = src
    t = START + i / fps
    out = render_frame(src, t)
    enc.stdin.write(out.tobytes())
    if args.poster and poster_t is not None and abs((t - START) - poster_t) < 0.5 / fps:
        out.save(args.poster, quality=90)
    if i % (fps * 2) == 0:
        print(f"  {t - START:5.1f} s", flush=True)
enc.stdin.close()
enc.wait()
dec.kill()
print("done:", args.out, os.path.getsize(args.out) // 1024, "KB")
