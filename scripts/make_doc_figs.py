# -*- coding: utf-8 -*-
"""Generate the two schematic figures used by the technical document.

Everything is drawn with PIL at print-scale: the canvas is sized so that when the
figure is placed at 13-14 cm in the DOCX the smallest text stays around 7 pt.
"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = r"D:\Gowin\voice\docs\figures"

INK = (32, 44, 62)
GREY = (110, 124, 142)
BLUE = (58, 108, 178)
BLUE_L = (232, 240, 250)
ORG = (196, 122, 40)
ORG_L = (253, 242, 228)
GRN = (42, 130, 96)
GRN_L = (230, 246, 238)
LINE = (140, 160, 186)


def font(size, bold=False):
    names = ([r"C:\Windows\Fonts\msyhbd.ttc"] if bold else []) + [
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
    ]
    for p in names:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            pass
    return ImageFont.load_default()


F_NAME = font(25, True)
F_DET = font(19)
F_COL = font(26, True)
F_NOTE = font(19)
F_SMALL = font(18, True)


def box(d, xy, title, lines, edge, fill, tfont=F_NAME, dfont=F_DET, pad=12):
    x0, y0, x1, y1 = xy
    d.rounded_rectangle(xy, radius=8, fill=fill, outline=edge, width=2)
    y = y0 + pad - 2
    d.text((x0 + pad, y), title, font=tfont, fill=edge)
    y += 32
    for ln in lines:
        d.text((x0 + pad, y), ln, font=dfont, fill=INK)
        y += 25


def arrow(d, p0, p1, color=BLUE, w=2, head=9):
    d.line([p0, p1], fill=color, width=w)
    x0, y0 = p0
    x1, y1 = p1
    if abs(x1 - x0) >= abs(y1 - y0):
        s = 1 if x1 > x0 else -1
        d.polygon([(x1, y1), (x1 - s * head, y1 - head // 2 - 1),
                   (x1 - s * head, y1 + head // 2 + 1)], fill=color)
    else:
        s = 1 if y1 > y0 else -1
        d.polygon([(x1, y1), (x1 - head // 2 - 1, y1 - s * head),
                   (x1 + head // 2 + 1, y1 - s * head)], fill=color)


# --------------------------------------------------------------- figure 1
def fig_system():
    W, H = 1300, 930
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    c1, c2, c3 = 16, 452, 888
    bw = 396

    d.text((c1, 16), "输入设备", font=F_COL, fill=BLUE)
    d.text((c2, 16), "FPGA 内部实时处理", font=F_COL, fill=BLUE)
    d.text((c3, 16), "输出 / 观测", font=F_COL, fill=BLUE)

    # left column
    box(d, (c1, 96, c1 + bw, 210), "8 键电容触摸 TTP229",
        ["两线轮询（SCL / SDO）", "16 bit 键位图，20 ms 抽头"], GRN, GRN_L)
    box(d, (c1, 250, c1 + bw, 364), "SW3 拨码 4 位",
        ["音区 2 位：C4 / C5 / C6 起", "音色 2 位：4 档波形"], ORG, ORG_L)
    box(d, (c1, 404, c1 + bw, 518), "板载按键 Key_1~3",
        ["音量＋ / 锁存叠加", "波表与显示页切换"], ORG, ORG_L)

    # middle column: audio chain
    chain = [
        ("输入处理 ttp229_rx", ["两级同步 + 边沿判定", "控制量 2 clk 内稳定"]),
        ("音符映射 keymap8", ["8 键 → C4 E4 G4 C5 E5", "G5 C6 E6，可锁存叠加"]),
        ("32 路振荡器 osc_bank", ["8 声部 × 4 加法分量", "32 个独立相位累加器"]),
        ("8 路包络 adsr", ["逐样本 ADSR，5 Hz ±30 音分", "滑音指数逼近 95 ms"]),
        ("混音 mixer16", ["8 声部求和 + 立体声声像", "每帧 1 次 13/16 乘法"]),
        ("音量与软限幅 audio_out", ["13 位 Q8 增益 0.5×~16×", "3/4 满刻度、斜率 1/8"]),
        ("I2S 发送 i2s_tx", ["16 bit/声道，BCLK 1.5429 MHz", "帧长 2240 clk = 48 214.29 Hz"]),
    ]
    y = 96
    ys = []
    for name, det in chain:
        box(d, (c2, y, c2 + bw, y + 92), name, det, BLUE, BLUE_L)
        ys.append((y, y + 92))
        y += 108
    for i in range(len(ys) - 1):
        arrow(d, (c2 + bw // 2, ys[i][1]), (c2 + bw // 2, ys[i + 1][0] - 2))

    # right column: side blocks + outputs
    box(d, (c3, 96, c3 + bw, 190), "效果 fx_echo",
        ["延迟 / 混响 / 合唱共 1 块 BSRAM", "6 路抽头，时分复用"], ORG, ORG_L)
    box(d, (c3, 212, c3 + bw, 306), "显示 lcd_scope",
        ["波形快照 / 16 bin 频谱 / 李萨如", "480×272 RGB，像素时钟 9 MHz"], ORG, ORG_L)
    box(d, (c3, 328, c3 + bw, 422), "4.3 英寸 480×272 RGB 屏",
        ["RGB565，59.94 Hz，40P FPC", "三页轮播 + 8 根包络柱"], GRN, GRN_L)
    box(d, (c3, 452, c3 + bw, 546), "测试模式 test_mode",
        ["8 声部输出 8 个不同频率", "频谱页可见 8 根独立谱峰"], ORG, ORG_L)
    box(d, (c3, 700, c3 + bw, 794), "MAX98357 I2S 功放",
        ["3.2 W D 类，I2S 三线直驱", "8 Ω 喇叭"], GRN, GRN_L)

    # observation taps from the mixer, and the two output arrows
    map_x = c2 + bw
    arrow(d, (map_x, ys[4][1] - 26), (c3 - 4, 186), ORG, 2)
    arrow(d, (map_x, ys[4][1] - 14), (c3 - 4, 300), ORG, 2)
    arrow(d, (c3 + bw // 2, 306), (c3 + bw // 2, 328 - 2), BLUE, 2)
    arrow(d, (map_x, 760), (c3 - 4, 760), BLUE, 2)

    # notes
    d.line([16, 846, W - 16, 846], fill=LINE, width=1)
    d.text((16, 856), "① 控制信号 → 音频输出总延迟 62.38 µs（要求 ≤10 ms，余量 160 倍），逐时钟可推导",
           font=F_NOTE, fill=INK)
    d.text((16, 884), "② 混音吞吐量 32 × 48 214.29 = 1.54 M 振荡器·次/秒；全部在 FPGA 内逐样本计算，无预录 PCM",
           font=F_NOTE, fill=INK)
    img.save(os.path.join(OUT, "fig1_system.png"))
    print("fig1", img.size)


# --------------------------------------------------------------- figure 2
def fig_flow():
    W, H = 1320, 590
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    bw, bh = 600, 104
    xs = [40, 680]
    ys = [30, 150, 270, 390]
    steps = [
        ("赛题拆解与选型", ["确认全 HDL 音频通路 + 触摸输入 + 板内显示", "选定 GW2A-18，核对 Dock 原理图可用引脚"]),
        ("时钟与帧结构设计", ["27 MHz → rPLL 108 MHz；帧长 2240 clk", "采样率 48 214.29 Hz，全部分频为整数关系"]),
        ("自顶向下划分模块", ["13 个 RTL 模块按 8 层划分", "层间接口单向，无双向握手"]),
        ("逐模块自检平台", ["iverilog 建立 17 个测试平台", "每次改动全量回归"]),
        ("综合与布局布线", ["迭代时序：Fmax 59.3 → 109.485 MHz", "建立余量由负转正，0 违例端点"]),
        ("上板 bring-up", ["按「屏幕—触摸—音频」排序排查", "逐项定位并修复 6 个致命问题"]),
        ("交互与显示迭代", ["锁存叠加、三页显示、波表", "颤音滑音、延迟混响合唱、测试模式"]),
        ("量化验收", ["延迟 62.38 µs，吞吐 1.54 M", "0 告警、0 违例、35 脚逐条核对"]),
    ]
    for i, (name, det) in enumerate(steps):
        col = 0 if i < 4 else 1
        row = i if i < 4 else i - 4
        edge, fill = (BLUE, BLUE_L) if i < 7 else (GRN, GRN_L)
        box(d, (xs[col], ys[row], xs[col] + bw, ys[row] + bh), name, det, edge, fill)

    for col in (0, 1):
        for row in range(3):
            arrow(d, (xs[col] + bw // 2, ys[row] + bh), (xs[col] + bw // 2, ys[row + 1] - 2))

    # turn: bottom of the left column across the gutter and up into the right column
    gx = 660
    d.line([(xs[0] + bw // 2, ys[3] + bh), (xs[0] + bw // 2, ys[3] + bh + 14)], fill=BLUE, width=2)
    d.line([(xs[0] + bw // 2, ys[3] + bh + 14), (gx, ys[3] + bh + 14)], fill=BLUE, width=2)
    d.line([(gx, ys[3] + bh + 14), (gx, ys[0] + bh // 2)], fill=BLUE, width=2)
    arrow(d, (gx, ys[0] + bh // 2), (xs[1] - 2, ys[0] + bh // 2), BLUE, 2)

    d.text((xs[0], 528), "任一阶段出现回归失败，都回到对应模块的测试平台重跑，再重新进入综合与时序收敛阶段。",
           font=F_NOTE, fill=GREY)

    img.save(os.path.join(OUT, "fig2_flow.png"))
    print("fig2", img.size)


WHITE = (255, 255, 255)
fig_system()
fig_flow()
