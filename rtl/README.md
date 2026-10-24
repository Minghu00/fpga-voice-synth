# rtl/ —— 按功能板块组织的 Verilog 源码

一次音频帧（2240 个 108 MHz 时钟）被切成四段互不重叠的时隙，所以同一个
振荡器乘法器、同一个正弦 ROM 可以被 32 路复用，而不需要 32 份硬件：

```
 fc:  0        1024      1088       1152          2240
     |  振荡器  |  包络   |  混音   |     I2S / 显示  |
        osc_ph    env_ph    mix_ph     空闲
```

## 板块

### `top/` —— 顶层
| 文件 | 模块 | 说明 |
|---|---|---|
| `top_inst.v` | `top_inst` | 8 键乐器顶层。例化时钟、输入、音频、显示四块，参数全部可覆盖（testbench 用它把帧长压短）。**接线表见 `乐器位流说明.md`** |

### `clock/` —— 时钟
| 文件 | 模块 | 说明 |
|---|---|---|
| `pll_sys.v` | `pll_sys` | 27 MHz → **108 MHz**。`IDIV_SEL=0, FBDIV_SEL=3, ODIV_SEL=8`。注意高云 rPLL 的真实关系是 `CLKOUT = FCLKIN×(FBDIV+1)/(IDIV+1)`，`ODIV` **只是把 VCO 摆进 500..1250 MHz 区间、不分频 CLKOUT** —— 写成 `VCO/ODIV` 会得到 864 MHz 的错误约束。仿真时用 `sim/pll_sys_sim.v` 替身 |

### `input/` —— 人机输入
| 文件 | 模块 | 说明 |
|---|---|---|
| `ttp229_rx.v` | `ttp229_rx` | TTP229 两线轮询：主动驱动 SCL 读 16 位键位图。参数 `INIT_CLK`（上电等待）/ `POLL_CLK`（轮询周期）/ `SCL_HALF`（SCL 半周期 108 clk = 1 µs）/ `ACTIVE_LOW` |
| `keymap8.v` | `keymap8` | 键位图 → 8 声部 `note_flat` + `gate`；DIP 选八度/音色；`vup` 按键（音量 +1，带 5.3 ms 去抖）；锁存模式开关；测试音选通 |

### `audio/` —— 合成与输出
| 文件 | 模块 | 说明 |
|---|---|---|
| `frame_gen.v` | `frame_gen` | 帧内相位发生器：`fc` 0..2239，以及 `sample_tick` / `osc_ph` / `env_ph` / `mix_ph` 四个时隙标志 |
| `inc_lut.v` | `inc_lut` | 34 个音名 → 32 位相位增量（`inc = f × 2^32 / fs`），纯组合查找 |
| `sine_rom.v` | `sine_rom` | 1024×16 位**二进制补码有符号**正弦表，`$readmemh` 读 `rtl/audio/sine_1024.mem` |
| `sine_1024.mem` | — | 正弦数据。**路径写死在 `sine_rom.v:29`，移动文件只改那一行** |
| `osc_bank.v` | `osc_bank` | 核心。`VOICES` 个声部 × `VOICES×NCOMP` 个独立相位累加器，时分复用一套 ROM + 乘法器；输出 `raw_flat`（每声部 16 位有符号，叠加了各分量）。相位存 BSRAM |
| `adsr.v` | `adsr` | 5 态包络（IDLE/ATT/DEC/SUS/REL）。`ATT_STEP/DEC_STEP/REL_STEP/SUSTAIN` 全是参数，换音色只改参数 |
| `mixer16.v` | `mixer16` | `VOICES` 路求和 + ±32767 饱和。`MIX_SHIFT` 是统一右移（防溢出） |
| `audio_out.v` | `audio_out` | 音量（13 位 Q8，128..4096 = 0.5×..16×，默认索引 6 = 4.0×）、静音、测试音（94 Hz −12 dBFS 方波，绕过合成器） |
| `i2s_tx.v` | `i2s_tx` | 标准 I2S 串行器。16 位/槽，`BCLK_HALF=35` → BCLK 1.5429 MHz；帧长**精确** 2240 clk，与音频帧锁相。`load_tick` 捕获到 `shadow_l/shadow_r`，帧边界再装载 |

### `display/` —— 480×272 RGB 屏
| 文件 | 模块 | 说明 |
|---|---|---|
| `lcd_timing.v` | `lcd_timing` | 同步产生器。`DIV=12` → 9 MHz 像素时钟；H 480+2+41+2=525、V 272+2+10+2=286 → 59.94 Hz。HS/VS 低有效，DE 高有效 |
| `wave_buf.v` | `wave_buf` | 512×16 双口 BSRAM，存混音历史给示波器用（同地址读写返回旧值） |
| `lcd_scope.v` | `lcd_scope` | 全部画面。分区：y0..15 状态条（八度/音色/音量梯）、y16..47 灰阶、y48..111 波形示波器（**过零触发**）、y112..175 8 根包络柱、y176..207 16 色块、y208..271 8 个触摸格 |

### `legacy/` —— 历史版本（仍可综合，用于对照）
`top.v`（4 声部）、`keymap.v`、`lat_counter.v`、`lcd_panel.v`、`top_lcd.v`、`top_lcd_test.v`。
这六个文件被 `poly_synth.gprj` / `lcd_test.gprj` / `lcd_only.gprj` 引用；`inst.gprj` 不用它们。

### `_reserved/` —— 待实现功能的预置位置
**不在任何 `.gprj` 里**，所以不参与综合、不影响当前位流。详见 `_reserved/README.md`。

## 改代码时的约定

1. **模块不得依赖自己的物理路径**，除了 `sine_rom.v` 的 `$readmemh`（它按
   工程根目录解析，这是 Gowin 和 iverilog 唯一共同的约定）。
2. 新增模块后要同时改三处：`*.gprj` 的 `<FileList>`、`scripts/run_all_sim.ps1`
   的 `$RTL`、`scripts/sim.ps1` 的 `$rtl`。
3. **不要用 PowerShell 的 `Out-File`/`Set-Content -Encoding utf8` 写 `.v` 文件**
   —— 会写下 BOM，iverilog 报 `No top level modules`。用编辑工具直接保存。
4. 出现意料之外的 `X` 或卡死，优先查**帧相位**：`fc` 的每个时隙边界必须严格
   对应 `OSC_END=1024 / ENV_END=1088 / MIX_END=1152`，改其中一个参数要同步检查
   其他模块里对 `fc` 的比较值。
