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
| `top_inst.v` | `top_inst` | 8 键乐器顶层。例化时钟、输入、音频、显示四块，参数全部可覆盖（testbench 用它把帧长压短）。**接线表见 `乐器位流说明.md`**。内含**抗来回报键的锁存**：`TAP_HOLD`（默认 965 样本 ≈20 ms）内连续被报满才算一次点按，且 `tap_done` 只在 `gate_live == 0` 时清零 —— 芯片单键模式两指同时按会每次扫描换着报键，旧写法 `latch ^= key_rise` 会不停把音翻掉（听起来就是「颤抖」），回归见 `sim/tb_latch.v` |

### `clock/` —— 时钟
| 文件 | 模块 | 说明 |
|---|---|---|
| `pll_sys.v` | `pll_sys` | 27 MHz → **108 MHz**。`IDIV_SEL=0, FBDIV_SEL=3, ODIV_SEL=8`。注意高云 rPLL 的真实关系是 `CLKOUT = FCLKIN×(FBDIV+1)/(IDIV+1)`，`ODIV` **只是把 VCO 摆进 500..1250 MHz 区间、不分频 CLKOUT** —— 写成 `VCO/ODIV` 会得到 864 MHz 的错误约束。仿真时用 `sim/pll_sys_sim.v` 替身 |

### `input/` —— 人机输入
| 文件 | 模块 | 说明 |
|---|---|---|
| `ttp229_rx.v` | `ttp229_rx` | TTP229 两线轮询：主动驱动 SCL 读 16 位键位图。参数 `INIT_CLK`（上电等待）/ `POLL_CLK`（轮询周期）/ `SCL_HALF`（SCL 半周期 108 clk = 1 µs）/ `ACTIVE_LOW` |
| `keymap8.v` | `keymap8` | 键位图 → 8 声部 `note_flat` + `gate`；DIP 选八度/音色；`vup` 按键（音量 +1，档位 **2..10 = 0 dB..+24 dB**，上电默认 6=+12 dB，带 5.3 ms 去抖）；锁存模式开关；测试音选通 |

### `audio/` —— 合成与输出
| 文件 | 模块 | 说明 |
|---|---|---|
| `frame_gen.v` | `frame_gen` | 帧内相位发生器：`fc` 0..2239，以及 `sample_tick` / `osc_ph` / `env_ph` / `mix_ph` 四个时隙标志 |
| `inc_lut.v` | `inc_lut` | 25 音名（C4…C6，索引 0–24）→ 32 位相位增量（`inc = f × 2^32 / fs`），纯组合查找。溢出预算：`C6 ×4(谐波) = 0x1639E578 < 2^32`；再乘八度 ×4 就溢出，所以 `oct` 只允许 0..2 |
| `wavetable_bank.v` | `wavetable_bank` | **4 张波表**（正弦/三角/锯齿/方波各 1024 点）合成一块 4096×16 BSRAM，`{tab_sel, addr}` 寻址，**读延迟 1 拍、单读端口**（所以 `osc_bank` 的槽流水线一行不用改）。`$readmemh` 读 `rtl/audio/wav_bank_4096.mem` |
| `wav_bank_4096.mem` | — | 4096 行 × 16 位有符号：行 0–1023 正弦、1024–2047 三角、2048–3071 锯齿、3072–4095 方波。三张新表**带宽限到 8 次谐波**。行 0–1023 与旧 `sine_1024.mem` **逐行一致**。**路径写死在 `wavetable_bank.v` 的 `$readmemh`，移动文件只改那一行** |
| `osc_bank.v` | `osc_bank` | 核心。`VOICES` 个声部 × `VOICES×NCOMP` 个独立相位累加器，时分复用一套 ROM + 乘法器；输出 `raw_flat`（每声部 16 位有符号，叠加了各分量）。相位存 BSRAM。`wave_mode=1` 时 `tab_nx = cidx`（分量 c 读表 c）+ 幅度四等分。**帧尾预计算段**（`fc` 1024..1279）里同时跑 `pinc→inc_org` 的滑音逼近、`tgt_inc<<oct` 的八度移位、以及颤音乘性调制；这些都在 8 个声部/帧的低占空比窗口内完成，不进音频主路径 |
| `adsr.v` | `adsr` | 5 态包络（IDLE/ATT/DEC/SUS/REL）。`ATT_STEP/DEC_STEP/REL_STEP/SUSTAIN` 全是参数，换音色只改参数 |
| `mixer16.v` | `mixer16` | `VOICES` 路求和 + ±32767 饱和。`MIX_SHIFT` 是统一右移（防溢出）。**轻微声像**（给李萨如页用）：偶数声部偏左、奇数声部偏右，交叉系数 13/16（−1.8 dB）。**按奇偶分两个累加器 `acc_e`/`acc_o`，声像只在帧尾对两个部分和做一次**（`out_l = sum_e + 13/16·sum_o`），否则「乘法→移位加→选择→累加」四级串进一个周期只剩 +0.017 ns。`out = (sum_e+sum_o) >>> MIX_SHIFT` 与原单声道逐位相同 |
| `audio_out.v` | `audio_out` | 音量（13 位 Q8，128..4096 = 0.5×..16×，默认索引 6 = 4.0×）、静音、测试音（94 Hz −12 dBFS 方波，绕过合成器）、**软限幅器**（拐点 3/4 满刻度 24576，以上斜率 1/8，正负对称；硬削会把多音变成方波并产生 \|f1−f2\| 差拍，听起来像"颤抖"，见 `docs/音量与削波记录.md`） |
| `i2s_tx.v` | `i2s_tx` | 标准 I2S 串行器。16 位/槽，`BCLK_HALF=35` → BCLK 1.5429 MHz；帧长**精确** 2240 clk，与音频帧锁相。`load_tick` 捕获到 `shadow_l/shadow_r`，帧边界再装载 |
| `test_mode.v` | `test_mode` | 现场测试模式。上电 1 ms 窗口内按住 Key_3 即锁存 `test_en`（粘性，断电退出）；锁存后强制 `gate=全 1`、`note_flat=NOTE_SET`（8 个隔 3 半音的音）、`timbre=0`（单分量纯正弦）、`oct=0`、`vol=2`（1.0×）。**选通结果必须在模块内打一拍再输出**，否则那级 mux 会串进 `note→inc_lut→<<oct` 最紧路径，Fmax 从 119.6 掉到 108.85 MHz |

| （颤音 LFO） | — | **已内联进 `rtl/top/top_inst.v`**。原来的独立模块 `vibrato_lfo.v` 因为输出 `vib_abs` 无人使用，被 Gowin 以 `swept in optimizing` 整个删掉（等于颤音在硬件上失效）；现在 LFO 直接写在顶层，并把 `vib_abs` 接到 `lcd_scope` 让 FX 阶梯随 LFO 呼吸，实例才不会被优化。24 位相位累加器 + 32 项四分之一正弦表（192 bit 纯 LUT），`PH_INC=1740` → **4.998 Hz**；`osc_bank` 在预计算段做**乘性**调制 `inc_org = inc_org * (1024 + (vib*DEPTH>>10)) >> 10`，`DEPTH=18` → ±30 cent。**教训：新模块的每个输出都必须有真实消费者，否则综合会删掉它，而告警只是轻描淡写的 NL0002。** |
| `fx_echo.v` | `fx_echo` | **板内延迟 / 混响 / 合唱**，三者**共用一条** 8192×16 BSRAM 环形缓冲（169.9 ms），靠 **6 路抽头时分复用**区分：tap0 `DELAY=6000`（延迟 124.4 ms，湿 0.25，反馈 0.375）、tap1..4 `RV1..RV4 = 1784/2555/3424/4677`（混响 37/53/71/97 ms，权重 0.25/0.125/0.125/0.0625）、tap5 `CH_D=1024` 由三角波 LFO（0.60 Hz）调制 ±64（合唱）。BSRAM 只有一个读端口，所以**一个时钟读一路**，`en` 之后跑 8 拍（`TCYC=NTAP+2=8`），`en` 每 2240 拍才来一次，余量 280 倍。**收数据必须等 `tc-2`**（BSRAM 输出比地址晚一拍），写成 `tc-1` 会整体偏移一路抽头。回写前软限幅，写回由 flop 驱动、不经 BSRAM 输出。**所有内部求和都必须声明为 `wire signed [17:0]`**：曾用 `{din_q[15],din_q}` 手工做符号扩展，而 Verilog 的拼接**永远是无符号**，负样本被当成 65436，输出被 `sat16` 钉在 +32767，听感就是「多音颤抖」（见 `docs/音量与削波记录.md` 第 12 节） |
### `display/` —— 480×272 RGB 屏
| 文件 | 模块 | 说明 |
|---|---|---|
| `lcd_timing.v` | `lcd_timing` | 同步产生器。`DIV=12` → 9 MHz 像素时钟；H 480+2+41+2=525、V 272+2+10+2=286 → 59.94 Hz。HS/VS 低有效，DE 高有效 |
| `wave_buf.v` | `wave_buf` | 512×**32** 双口 BSRAM（`{R,L}`），存立体声混音历史给示波器 / 李萨如用（同地址读写返回旧值） |
| `spectrum16.v` | `spectrum16` | **16 bin 实时频谱**。512 点三角窗 DFT，`94.174 Hz/bin`（k=1..16，跳过 DC），覆盖 94 Hz..1.507 kHz。2 块 sin/cos BSRAM + 2 个乘法器时分复用，一个采样 16 槽 × 3 拍 = 48 clk（预算 2240）。输出 4 bit × 16 电平；AGC 以本块峰值 bin 为 0 dB、每档 3 dB，低于峰值 45 dB 读 0。`$readmemh` 读 `rtl/display/spectrum_sin.mem`。**16 组累加器是旋转阵列（当前 bin 恒为 slot 0），不用变址 mux**——用 `bctr`/`pctr` 索引寄存器数组会让 16:1 的 32 位读 mux 单独吃掉约 9 ns 路由，见 `docs/Fmax加固记录.md`。三个必留坑见文件头 |
| `liss_render.v` | `liss_render` | **李萨如预渲染器**。行消隐内把 512 个立体声点压成 512×16 的按列纵向拉幅表（`{ymax,ymin}`，空列 `{0,255}`）；`xb = clamp(240 + L>>>6, 0, 479)`、`y = clamp(68 + R>>>6, 0, 135)`。7 状态 FSM，3584 clk（预算 88200） |
| `lcd_scope.v` | `lcd_scope` | 全部画面。纵向分区（`localparam WAVE_Y0/Y1=28/164`、`ENV_Y0/Y1=164/232`、`STAT_Y0/Y1=232/240`、`BARS_Y0=240`）：`y0..27` 8 个触摸格、`y28..163` 波形示波器（**过零触发**，窗口起点每帧只锁一次）、`y164..231` 实心包络柱、`y232..239` 状态条、`y240..271` 8 根逐声部包络柱（每根 60 px）。频谱柱高改成**预计算表** `stop_tab[0..15]`（`spec_flat` 一变就刷新），柱顶路径从「DSP→16:1 mux→*4→减→比较」7 级缩成「DSP→16:1 mux→flop」；当前最紧路径已离开本模块。状态条横分 16 块（`sblk=(x×2731)>>15`，每块 30 px）：`sblk 0..3` 八度梯、`4..7` 音色梯、`8..12` 音量梯、`14..15` **TEST 红块**；另外 `y<18 && x>463` 是锁存模式紫标记 |

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
