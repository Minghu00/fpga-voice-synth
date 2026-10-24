# LCD + 触摸 bring-up 说明（v2 诊断版）

> 目的：在动音频之前，用一个**不含音频通路**的位流把屏点亮、并把 TTP229 的 16 位原始数据
> 直接画到屏上。接错线、认错采样边沿、位序差一位，都能一眼看出来，不用猜。
> I2S 三个脚在这个工程里**完全没有约束**，MAX98357 的 BCLK / LRC / DIN 悬空即可。

---

## 1. 工程与产物

| 项 | 路径 |
|---|---|
| 工程文件 | `lcd_test.gprj`（顶层 `top_lcd_test`） |
| 顶层 RTL | `rtl/top_lcd_test.v` |
| 复用模块 | `rtl/pll_sys.v`、`rtl/ttp229_rx.v`、`rtl/lcd_timing.v` |
| 管脚约束 | `constraints/lcd_test.cst` |
| 时序约束 | `constraints/lcd_test.sdc` |
| 构建脚本 | `scripts/build_lcd_test.ps1`（→ `tcl/build_lcd_test.tcl`） |
| 自检 TB | `sim/tb_lcd_test.v`、`sim/tb_ttp229_rx.v` |
| **位流** | **`impl_lcd_test/pnr/lcd_test.fs`**（4,620,698 B），另有 `lcd_test.bin`（577,178 B） |

烧录用 Gowin Programmer，设备选 `GW2A-18C`，External Flash Mode / SRAM Program 均可。

## 2. 接线

### 屏（Dock 上的 J7，40P 0.5mm FPC，直接插）

屏的 40P 排线插 J7 即可。`DISP` 在板上已接 +3V3（常亮），背光 `BL` 由 LP3320 升压驱动，
**本版本没有拉 BL 的 PWM，默认最亮**。

### 触摸（Dock 上的 J14，2×6 2.54mm 排针，丝印 "MIC Array Conn"）

| TTP229 模块引脚 | Dock J14 脚号 | 板上网络名 | FPGA 球号 |
|---|---|---|---|
| VCC | 1 或 2 | +3V3 | — |
| GND | 3 或 4 | GND | — |
| **SCL** | **8** | `MIC_DAT0` | **P8** |
| **SDO** | **7** | `MIC_DAT1` | **T8** |

J14 完整脚位（2×6，奇数在一侧 1/3/5/7/9/11，偶数在另一侧 2/4/6/8/10/12）：

```
  1  +3V3              2  +3V3
  3  GND               4  GND
  5  MIC_LED_CLK (P9)  6  MIC_LED_DAT (WS2812 灯链)
  7  MIC_DAT1  (T8)  <- 接模块 SDO
  8  MIC_DAT0  (P8)  <- 接模块 SCL
  9  MIC_DAT2  (R8)   10  MIC_DAT3 (T7)
 11  MIC_BCK   (T6)   12  MIC_WS   (P6)
```

> **注意：不是 5/6 脚。** 早期文档把触摸线误写成 5/6。原理图第 1 页 `007_Things` 子图实际是
> `DFP_IOR42_P`(P8) → `MIC_DAT0`、`DFP_IOR42_N`(T8) → `MIC_DAT1`，对应 J14 的 **8 脚和 7 脚**；
> 5/6 脚是 WS2812 灯链的 `MIC_LED_CLK` / `MIC_LED_DAT`，接上去完全不通。
>
> 若上电后 ROW A 与 ROW B 一个干净一个乱，先把 7/8 脚对调试一试（SCL/SDO 接反）。

### 复位

`rst_n` = **T3**（Dock 上 Silicon Key_1，低有效，`PULL_MODE=UP`）。上电默认释放，按下即复位。

## 3. 屏幕上应该看到什么

480×272 横屏，从上到下 7 个区：

| 行 | 内容 | 正常表现 |
|---|---|---|
| 0..15 | 状态条（整行宽） | **红** = 上电静默计时没走完；**黄** = 正在轮询但一个键都没读到；**绿** = 当前有键按下 |
| 16..47 | 灰阶带 | 32 级灰阶从左到右由黑到白（每 15 px 一级） |
| 48..111 | **ROW A**：SCL 低电平期采样的 16 位 | 16 格 × 30 px，第 i 格亮 = bit i 为 1 |
| 112..175 | **ROW B**：SCL 高电平期采样的 16 位 | 同上。**A 与 B 应该完全一样** |
| 176..207 | 16 色彩块 | 黑 红 绿 蓝 黄 品 青 白 / 暗红 暗绿 暗蓝 灰 钢 棕 琥珀 水色（每块 30 px） |
| 208..239 | **ROW C**：A XOR B | 全暗 = 两个边沿读到的一致；有格亮 = 数据在两个边沿之间变了 |
| 240..271 | 心跳块 | 亮白块每轮询一次（2 ms）向右跳一格，约 32 ms 转一圈 |

另有一根**白/亮紫竖线**每帧向右走一格（480 帧扫一遍），用来肉眼确认画面在刷新、没有卡住。
**看到这根线在动 = 时钟、时序、DE 全部正常。**

### 怎么用这三行定位问题

| 现象 | 结论 |
|---|---|
| 状态条红 | 触摸链路连上电都没起来，查 +3V3 / GND |
| 状态条黄、ROW A/B 全暗 | 在轮询但 SDO 一直是高 —— 查 SDO 是否接在 **J14 第 7 脚（T8）** |
| 按一个键，ROW A、ROW B 都只有**一格亮且位置相同** | 协议对了，把亮格位置和手指按的格子对一下即可验证位序 |
| ROW A 一格亮、ROW B 乱 | 该模块在 **SCL 低电平期**出数据 → 用 ROW A |
| ROW B 一格亮、ROW A 乱 | 该模块在 **SCL 上升沿**出数据 → 用 ROW B |
| 两行都一格亮但位置差 1 格 | 位序差一位，把差的位置告诉我即可改映射 |
| 亮格数 > 1 | 多个 TP 被判为按下，多半是 SCL 太快或没接 GND |
| 按一下亮、松手不灭 | 轮询没在跑，看心跳块有没有在跳 |

## 4. 自检结果

`sim/tb_lcd_test.v`（11 项全过）：

```
PASS  DCLK half period in sys clocks (9 MHz) : 6      <- 108/12，半周期 6 clk
PASS  HS period in pixels : 525
PASS  VS period in lines  : 286
PASS  lines with a wrong DE count : 0                 <- 每行恰好 480 个有效像素
      ROW A lit = 1920   ROW B lit = 1920   ROW C = 0
PASS  ROW A lights exactly one 30 x 64 cell           <- 恰好 30 x 64 = 1920 像素
PASS  ROW B lights the same cell (both edges agree)
PASS  ROW C is dark when the two edges agree : 0
PASS  heartbeat block is drawn
PASS  the screen is not blank
PASS  ROW A dark after release : 0
PASS  ROW B dark after release : 0

== tb_lcd_test : ALL PASS ==
```

`sim/tb_ttp229_rx.v`（8 项全过）：

```
PASS  awake asserted after settle
PASS  no key touched : key_raw=0000
PASS  single key TP4 : key_raw=0010
PASS  single key TP4 (repeat) : key_raw=0010
PASS  keys TP0+TP15 : key_raw=8001
PASS  all 16 keys : key_raw=ffff
PASS  all released : key_raw=0000
PASS  pattern 1234 : key_raw=1234
PASS  low/high phase words agree : 1234

== tb_ttp229_rx : ALL PASS ==
```

一键回归：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sim.ps1`（9 个 bench 全过）。

## 5. 综合 / 布局布线结果（`impl_lcd_test/`）

| 项 | 值 |
|---|---|
| 综合 + 布线告警 | **0** |
| Logic | 312 / 20736（2%）：294 LUT + 18 ALU |
| Register | 242 / 16173（2%）：222 FF + 20 I/O FF |
| CLS | 247 / 10368（3%） |
| I/O Port | 24 / 207（12%），全部按约束落位 |
| BSRAM | 0 / 46 |
| rPLL | 1 / 4 |
| 时钟约束 | 108.000 MHz |
| **实际 Fmax** | **160.385 MHz**（余量 48%） |
| Setup / Hold TNS | 0.000 / 0.000，0 个违例端点 |

两个配置脚靠 `set_option -use_sspi_as_gpio 1` 放开（`lcd_dclk`=R9 兼 `FASTRD_N`、`lcd_r[2]`=N9 兼 `SSPI_CS_N`），
与 Sipeed 官方 480×272 例程一致，不影响 JTAG 烧录。

## 6. 排错对照表

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 全黑、无扫线 | 位流没跑 / 时钟没起 | 确认 `DONE`，量 H11 是否有 27 MHz |
| 全白 / 雪花 | HS/VS/DE 极性反了 | 本设计是 **HS/VS 低有效、DE 高有效**；换别的屏需改 `hsync_n` / `vsync_n` |
| 图像整体偏移 | 前后沿参数与本屏不符 | 本屏已知：H FP=2 SYNC=41 BP=2；V FP=2 SYNC=10 BP=2 |
| 色块颜色不对 | RGB 位序反了 | 本工程 `lcd_r[4]` 是 MSB（原例程 `lcd_r[0]` 接 R3，即 5 位里的 LSB 分配） |
| 状态条一直黄 | TTP229 没回数据 | 量 P8 上有没有 SCL 波形（空闲应为高）；确认 SDO 接在 T8 |
| 按键全亮 / 全不亮 | 模块 TP 引脚映射与预期不符 | 常见 8 键 + 功能脚版本，若只有 8 键则只会亮前 8 格 |
| 亮度偏暗 | 背光 BL 没拉高 | 本版本不驱动 BL；要调光需给 LP3320 的 EN 加 PWM |

## 7. 与完整工程的关系

屏和触摸都验证通过后，把音频通路接回 `rtl/top.v`（主工程已综合通过，Fmax 与资源见 `impl/`），
`impl/pnr/poly_synth.fs` 就是带 16 声部 × 4 分量正弦合成 + I2S + LCD 的完整位流。
