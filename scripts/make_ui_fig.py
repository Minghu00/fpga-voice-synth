# -*- coding: utf-8 -*-
"""Render a three-page mock of the on-board display (waveform / spectrum / Lissajous).

The pixel content is computed from the same numbers the RTL uses (48 214.2857 Hz
sample rate, 480-sample snapshot, 16 bins at 94.17 Hz/bin) so the picture shows
what the hardware actually draws.
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = r"D:\Gowin\voice\docs\figures"
FS = 108e6 / 2240.0
F1, F2 = 261.6256, 329.6276
W, H = 480, 272

BG = (18, 26, 176)
BG2 = (10, 16, 120)
CY = (90, 240, 250)
CY_D = (30, 130, 190)
ORG = (255, 150, 40)
GRN = (60, 230, 120)
YEL = (250, 230, 70)
WHT = (250, 250, 255)
MAG = (230, 120, 230)


def font(size, bold=False):
    names = ([r"C:\Windows\Fonts\msyhbd.ttc"] if bold else []) + [
        r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf"]
    for p in names:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            pass
    return ImageFont.load_default()


F9 = font(13)
F10 = font(14, True)


def status_bar(d):
    d.rectangle([0, 0, 112, 13], fill=CY)
    d.rectangle([120, 3, 150, 10], fill=WHT)       # volume ladder
    d.rectangle([158, 3, 188, 10], fill=YEL)       # fx preset
    d.rectangle([196, 3, 214, 10], fill=GRN)       # octave
    d.rectangle([222, 3, 240, 10], fill=CY_D)      # timbre


def page_wave():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    status_bar(d)
    d.text((300, 0), "PAGE 1/3  WAVE", font=F9, fill=WHT)
    # left column: 8 pad cells + 8 envelope bars
    for i in range(8):
        y0 = 16 + i * 32
        d.rectangle([2, y0, 30, y0 + 28], outline=CY_D, fill=(24, 34, 150))
        if i in (0, 1):
            d.rectangle([4, y0 + 2, 28, y0 + 26], fill=CY)
        d.rectangle([34, y0 + 26 - 20, 44, y0 + 26], fill=GRN if i in (0, 1) else (24, 34, 150))
    d.line([48, 14, 48, H - 2], fill=CY_D)
    # trace: exactly the 480 samples of the snapshot
    t = np.arange(W) / FS
    v = np.sin(2 * np.pi * F1 * t) + np.sin(2 * np.pi * F2 * t)
    v = v / 2.0
    mid = 16 + (H - 18) / 2.0
    amp = (H - 18) / 2.0 * 0.85
    pts = [(50 + i, mid - v[i] * amp) for i in range(W - 50)]
    d.line(pts, fill=CY, width=1)
    d.line([50, mid, W - 1, mid], fill=(60, 80, 170))
    return img


def page_spec():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    status_bar(d)
    d.text((300, 0), "PAGE 2/3  SPEC", font=F9, fill=WHT)
    # true 16-bin DFT of the same 480 samples
    t = np.arange(W) / FS
    x = np.sin(2 * np.pi * F1 * t) + np.sin(2 * np.pi * F2 * t)
    bins = 16
    df = FS / W  # true resolution of a 480-point block = 100.4 Hz
    mags = []
    for k in range(bins):
        fk = 94.17 * (k + 1)
        w = np.exp(-2j * np.pi * fk * t)
        mags.append(abs(np.dot(x, w)) / W)
    mags = np.array(mags)
    mags = mags / mags.max()
    base = H - 20
    bw = 24
    for k, m in enumerate(mags):
        x0 = 12 + k * 28
        h = max(2, int(m * (H - 60)))
        col = CY if m > 0.35 else CY_D
        d.rectangle([x0, base - h, x0 + bw, base], fill=col)
    d.line([6, base, W - 6, base], fill=(70, 90, 180))
    d.text((8, H - 16), "94 Hz", font=F9, fill=WHT)
    d.text((W - 92, H - 16), "1.51 kHz", font=F9, fill=WHT)
    return img


def page_liss():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    status_bar(d)
    d.text((300, 0), "PAGE 3/3  XY", font=F9, fill=F9 and WHT)
    cx, cy = W / 2.0, 16 + (H - 18) / 2.0
    r = (H - 30) / 2.0
    t = np.linspace(0, 1.0 / 68.0, 6000)
    # L carries voice A louder, R carries voice B louder (the 13/16 pan law)
    l = np.sin(2 * np.pi * F1 * t) + 13 / 16 * np.sin(2 * np.pi * F2 * t)
    rr = 13 / 16 * np.sin(2 * np.pi * F1 * t) + np.sin(2 * np.pi * F2 * t)
    m = max(abs(l).max(), abs(rr).max())
    pts = [(cx + l[i] / m * r, cy - rr[i] / m * r) for i in range(0, len(t), 6)]
    d.line(pts, fill=CY, width=1)
    d.line([cx - r - 6, cy, cx + r + 6, cy], fill=(60, 80, 170))
    d.line([cx, 16, cx, H - 4], fill=(60, 80, 170))
    return img


panels = [
    ("波形页：480 点快照（9.96 ms），两个音的拍频包络清晰可见", page_wave()),
    ("频谱页：16 通道 DFT，C4 与 E4 各占一根谱峰，其余低于 −20 dB", page_spec()),
    ("李萨如页：X = 左声道，Y = 右声道；奇偶交替声像的窄带闭合曲线", page_liss()),
]

PAD, LBL = 18, 26
CW = W + PAD * 2
CH = H + LBL + PAD
canvas = Image.new("RGB", (CW, CH * 3), (255, 255, 255))
d = ImageDraw.Draw(canvas)
for i, (label, im) in enumerate(panels):
    y = i * CH + PAD
    d.text((PAD, y - LBL + 2), label, font=F10, fill=(30, 40, 60))
    canvas.paste(im, (PAD, y))

canvas.save(os.path.join(OUT, "fig7_ui.png"))
print("fig7_ui", canvas.size)
