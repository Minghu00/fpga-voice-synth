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
| `inc_lut.v` | `inc_lut` | 25 音名（C4…C6，索引 0–24）→ 32 位相位增量（`inc = f × 2^32 / fs`），纯组合查找。溢出预算：`C6 ×4(谐波) = 0x1639E578 < 2^32`；再乘八度 ×4 就溢出，所以 `oct` 只允许 0..2 |
| `wavetable_bank.v` | `wavetable_bank` | **4 张波表**（正弦/三角/锯齿/方波各 1024 点）合成一块 4096×16 BSRAM，`{tab_sel, addr}` 寻址，**读延迟 1 拍、单读端口**（所以 `osc_bank` 的槽流水线一行不用改）。`$readmemh` 读 `rtl/audio/wav_bank_4096.mem` |
| `wav_bank_4096.mem` | — | 4096 行 × 16 位有符号：行 0–1023 正弦、1024–2047 三角、2048–3071 锯齿、3072–4095 方波。三张新表**带宽限到 8 次谐波**。行 0–1023 与旧 `sine_1024.mem` **逐行一致**。**路径写死在 `wavetable_bank.v` 的 `$readmemh`，移动文件只改那一行** |
| `osc_bank.v` | `osc_bank` | 核心。`VOICES` 个声部 × `VOICES×NCOMP` 个独立相位累加器，时分复用一套 ROM + 乘法器；输出 `raw_flat`（每声部 16 位有符号，叠加了各分量）。相位存 BSRAM。`wave_mode=1` 时 `tab_nx = cidx`（分量 c 读表 c）+ 幅度四等分。**帧尾预计算段**（`fc` 1024..1279）里同时跑 `pinc→inc_org` 的滑音逼近、`tgt_inc<<oct` 的八度移位、以及颤音乘性调制；这些都在 8 个声部/帧的低占空比窗口内完成，不进音频主路径 |
| `adsr.v` | `adsr` | 5 态包络（IDLE/ATT/DEC/SUS/REL）。`ATT_STEP/DEC_STEP/REL_STEP/SUSTAIN` 全是参数，换音色只改参数 |
| `mixer16.v` | `mixer16` | `VOICES` 路求和 + ±32767 饱和。`MIX_SHIFT` 是统一右移（防溢出） |
| `audio_out.v` | `audio_out` | 音量（13 位 Q8，128..4096 = 0.5×..16×，默认索引 6 = 4.0×）、静音、测试音（94 Hz −12 dBFS 方波，绕过合成器） |
| `i2s_tx.v` | `i2s_tx` | 标准 I2S 串行器。16 位/槽，`BCLK_HALF=35` → BCLK 1.5429 MHz；帧长**精确** 2240 clk，与音频帧锁相。`load_tick` 捕获到 `shadow_l/shadow_r`，帧边界再装载 |
| `test_mode.v` | `test_mode` | 现场测试模式。上电 1 ms 窗口内按住 Key_3 即锁存 `test_en`（粘性，断电退出）；锁存后强制 `gate=全 1`、`note_flat=NOTE_SET`（8 个隔 3 半音的音）、`timbre=0`（单分量纯正弦）、`oct=0`、`vol=2`（1.0×）。**选通结果必须在模块内打一拍再输出**，否则那级 mux 会串进 `note→inc_lut→<<oct` 最紧路径，Fmax 从 119.6 掉到 108.85 MHz |

| `vibrato_lfo.v` | `vibrato_lfo` | 颤音 LFO。24 位相位累加器 + 32 项四分之一正弦表（192 bit 纯 LUT，不占 BSRAM），相位增量 `PH_INC=1740` → **4.998 Hz**。输出 `vib_d`（Q10，±1024）与 `d_abs`。全局共用一个实例（各声部同相，听感自然），由 `osc_bank` 在预计算段做**乘性**调制：`inc_org = inc_org * (1024 + (vib*DEPTH>>10)) >> 10`，`DEPTH=18` → ±30 cent |
| `fx_echo.v` | `fx_echo` | **板内延迟**。8192×16 BSRAM（4 块）环形缓冲，`D=6000` 采样 → **124.4 ms**。反馈 `0.375`、湿声 `0.25`，回写前软限幅。反馈路径打了一拍（读 → 算 → 写跨两个时钟），否则这条环路会把 Fmax 拖到 100 MHz 以下。`TEST_LOOP=1` 时直通（写 = 读），给 TB 做逐拍比对 |
### `display/` —— 480×272 RGB 屏
| 文件 | 模块 | 说明 |
|---|---|---|
| `lcd_timing.v` | `lcd_timing` | 同步产生器。`DIV=12` → 9 MHz 像素时钟；H 480+2+41+2=525、V 272+2+10+2=286 → 59.94 Hz。HS/VS 低有效，DE 高有效 |
| `wave_buf.v` | `wave_buf` | 512×16 双口 BSRAM，存混音历史给示波器用（同地址读写返回旧值） |
| `lcd_scope.v` | `lcd_scope` | 全部画面。纵向分区（`localparam WAVE_Y0/Y1=28/164`、`ENV_Y0/Y1=164/232`、`STAT_Y0/Y1=232/240`、`BARS_Y0=240`）：`y0..27` 8 个触摸格、`y28..163` 波形示波器（**过零触发**，窗口起点每帧只锁一次）、`y164..231` 实心包络柱、`y232..239` 状态条、`y240..271` 8 根逐声部包络柱（每根 60 px）。状态条横分 16 块（`sblk=(x×2731)>>15`，每块 30 px）：`sblk 0..3` 八度梯、`4..7` 音色梯、`8..12` 音量梯、`14..15` **TEST 红块**；另外 `y<18 && x>463` 是锁存模式紫标记 |

### `legacy/` —— 历史版本（仍可综合，用于对照）
`top.v`（4 声部）、`keymap.v`、`lat_counter.v`、`lcd_panel.v`、`top_lcd.v`、`top_lcd_test.v`。
这六个文件被 `poly_synth.gprj` / `lcd_test.gprj` / `lcd_only.gprj` 引用；`inst.gprj` 不用它们。

### `_reserved/` —— 待实现功能的预置位置
**不在任何 `.gprj` 里**，所以不参与综合、不影响当前位流。详见 `_reserved/README.md`。

## 改代码时的约定

1. **模块不得依赖自己的物理路径**，除了 `wavetable_bank.v` 的 `$readmemh`（它按
   工程根目录解析，这是 Gowin 和 iverilog 唯一共同的约定）。
2. 新增模块后要同时改三处：`*.gprj` 的 `<FileList>`、`scripts/run_all_sim.ps1`
   的 `$RTL`、`scripts/sim.ps1` 的 `$rtl`。
3. **不要用 PowerShell 的 `Out-File`/`Set-Content -Encoding utf8` 写 `.v` 文件**
   —— 会写下 BOM，iverilog 报 `No top level modules`。用编辑工具直接保存。
4. 出现意料之外的 `X` 或卡死，优先查**帧相位**：`fc` 的每个时隙边界必须严格
   对应 `OSC_END=1024 / ENV_END=1088 / MIX_END=1152`，改其中一个参数要同步检查
   其他模块里对 `fc` 的比较值。
5. **新功能凡是"选通 / 旁路"已有信号，一律先在模块内部打一拍再输出**。
   P0 的 `test_mode` 第一版用 `output wire` + `assign`，那 1 级 mux 正好串在
   `note → inc_lut → <<oct` 这条最紧路径前面，Fmax 从 119.185 掉到 108.850 MHz
   （约束 108，只剩 0.8%）。改成 `reg` 输出后就恢复了。
6. **状态条的横向坐标不要用窄位宽的倒数乘法**。`{10'b0, x} * 20'd2731` 在 `x ≥ 384`
   时溢出回绕，会让右半边重复点亮、标识块糊成一大片。用 22 位乘法 + 显式区间判断。
7. **跨时钟域 / 跨 BSRAM 的反馈环必须靠"多周期许可信号"拆开**，不要指望把组合逻辑
   写紧凑就能过时序。`fx_echo` 的「BSRAM 读出 → 反馈增益 → 相加 → 限幅 → 写回」一条
   环：用真乘法器 109.734 MHz、换成纯移位反而 108.315 MHz（证明瓶颈在环而不在运算），
   最后用 `vld <= {vld[1:0], en}` 把它拆成三个 `en` 周期（抓 tap → 算增益 → 写回），
   反馈端口由触发器驱动，Fmax 回到 116.540 MHz。因为 `en` 每 2240 clk 才来一次，
   两拍额外延迟是**完全免费**的。
8. **流水化之后一定要重跑 testbench**：`fx_echo` 拆成三级时漏写了 `din_q <= din;`
   （只写了做写回的 `dinq`），干路输出恒 0，`tb_fx_echo` 立刻报
   `on=0: output is the input delayed by exactly 2 samples`。没有断言就会一路带到板上。
