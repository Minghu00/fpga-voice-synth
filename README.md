# voice — 基于 FPGA 的实时多音色合成电子乐器引擎

高云 GW2A-18（Tang Primer 20K + Dock 3709/3714）上的实时数字乐器。
8 键电容触摸 → 32 路独立振荡器（8 声部 × 4 加法分量）→ 逐样本包络与混音
→ I2S 功放，同时把混音波形与包络历史画到 480×272 RGB 屏上。

- 采样率 **48 214.2857 Hz**（108 MHz / 2240），全部整数关系，无小数时钟
- 控制信号 → 音频输出延迟 **62.38 µs**（赛题要求 ≤10 ms，余量 160×）
- 混音吞吐量 **32 × 48 214.29 = 1.54 M 振荡器·次/秒**
- 综合实测 **0 告警**，Fmax **108.551 MHz**（约束 108 MHz，setup slack **+0.047 ns**）。
  当前最紧的一处是 `lcd_scope` 的颜色判定链（`y_q` 要穿四级串联比较才到 `nr`），
  完整分析见 `docs/Fmax加固记录.md`。
- 支持**现场测试模式**（上电时按住 Key_3）：8 个声部输出 8 个不同频率的纯正弦，
  频谱上 8 根互不重叠的谱峰 → `docs/测试模式证据.md`
- 支持**多波表模式**（长按 Key_3 约 0.8 s）：4 个加法分量各读一张独立波表
  （正弦 / 三角 / 锯齿 / 方波），坐实「4 个独立波表振荡器」→ `docs/多波表证据.md`
- 支持**表情 / 效果档**（长按 Key_2 约 0.8 s，共 8 档）：**颤音**（5 Hz、±30 cent）、
  **滑音**（声部 0 跟随最近按键，指数逼近 ≈95 ms）、**板内延迟**（8192×16 BSRAM，
  124.4 ms，反馈 0.375，湿声 0.25）→ `docs/滑音颤音延迟证据.md`

## 怎么用

### 综合出位流

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_inst.ps1
```

产物在 `impl_inst\pnr\inst.fs`（烧录用）与 `inst.bin`。
脚本会把 `rtl\`、`constraints\`、`inst.gprj`、`tcl\build_inst.tcl` 拷到
`%TEMP%\inst_build\` 再调 `gw_sh.exe`，所以本地源码目录不会被 Gowin 产生的
中间文件污染。

需要 Gowin EDA 在 `D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin`（可用
`-GowinBin` 参数覆盖）。

### 跑仿真

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_all_sim.ps1
```

十四个自检 testbench 全部 `ALL PASS` 才算通过。需要 iverilog 在
`D:\Gowin\tools\iverilog\bin`。单跑某个平台用 `scripts\sim.ps1 tb_inst`。

## 目录

| 路径 | 内容 |
|---|---|
| `rtl/` | 全部 Verilog，按板块分目录，见 `rtl/README.md` |
| `sim/` | 自检 testbench + TTP229 行为模型 + rPLL 仿真替身 |
| `constraints/` | `.cst` 管脚约束 + `.sdc` 时序约束（每套工程各一对） |
| `scripts/` | 构建与仿真的一键脚本 |
| `tcl/` | `gw_sh` 批处理脚本（每套工程一个） |
| `docs/datasheet_ttp229/` | TTP229 数据手册（PDF + 提取的 TXT） |
| `legacy/` | 第一代手工 `synth_voice` 设计，已废弃，仅存档 |
| `impl*/` | Gowin 输出（**不入库**，由 `scripts\build_*.ps1` 再生） |

### 四套工程

| 工程 | 顶层 | 用途 |
|---|---|---|
| `inst.gprj` | `rtl/top/top_inst.v` | **当前量产**：8 键乐器 + I2S + 波形/包络显示 |
| `poly_synth.gprj` | `rtl/legacy/top.v` | 早期 4 声部版本（保留可对照） |
| `lcd_test.gprj` | `rtl/legacy/top_lcd_test.v` | 显示 + 触摸点亮自检色带 |
| `lcd_only.gprj` | `rtl/legacy/top_lcd.v` | 纯显示验证（无触摸） |

## 文档

| 文件 | 内容 |
|---|---|
| `乐器位流说明.md` | **接线表、拨码表、触摸键↔音名、排错表**（上板必读） |
| `LCD接口映射.md` | 40P 屏 → J7 FPC 逐脚对应、时序参数 |
| `赛题方案.md` | 赛题解读与技术路线 |
| `赛题符合性对照.md` | 赛题每一条要求 vs 当前实现 |
| `交互方案_TTP229.md` | 触摸方案选型与 2-wire 协议细节 |
| `延迟达标分析.md` | 延迟口径与逐级拆解 |
| `实现与验证报告.md` | 各模块验证记录 |
| `显示方案_RGB.md` / `LCD验证说明.md` | 显示分区设计与自检方法 |
| `项目清单.md` | 最早的文件清单与 bug 排查记录 |

## 已知硬件约束（改设计前务必先读）

1. **TTP229 出厂是“全单键”模式**（`TP3=TP4=1`），芯片只报一个键。代码已按
   位图写好、支持真正多键，但要物理改 `TP3`/`TP4` 才能生效。见
   `交互方案_TTP229.md`。
2. **J14 的 P6 与 T6 脚位是反的**：第 11 脚是 `MIC_BCK`(T6)，第 12 脚是
   `MIC_WS`(P6)。`i2s_din` 必须在 T6，历史上错写成 P6 导致“仿真全过、上板无声”。
3. **屏是 RGB555/666/555**，不是 888：R、B 各 5 位，G 6 位，低位在 Dock 上直接接地。
4. `Silicone Key_n` 网络都有 **10 k 上拉到 +1V5**，按下才是 0，因此**不能**做
   电平型静音键（上电即静音）；现改为“音量 +1”按键。
