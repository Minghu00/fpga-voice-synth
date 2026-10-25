# rtl/_reserved/ —— 待实现功能的预置位置

这里放的是**尚未接入设计的功能骨架**。它们：

- **不在任何 `.gprj` 的 `<FileList>` 里** → 不参与综合，当前位流的资源用量、
  时序、管脚**完全不受影响**；
- 每个文件都是**能独立编译**的合法 Verilog（iverilog `-g2005` 通过），骨架里
  写明了预期端口和插入点，实现时补充逻辑即可，不必重新想接口；
- 由 `scripts/build_inst.ps1` 顺手拷进临时构建目录（它是 `rtl\*` 递归拷贝），
  但因为不在 gprj 里，Gowin 不会看它们，也不会产生 swept 告警。

## 清单

| 文件 | 目标 | 对应赛题条目 | 预计工作量 |
|---|---|---|---|
| ~~`test_mode.v`~~ | ✅ **已实现**，已移入 `rtl/audio/test_mode.v` 并接入 `inst.gprj` | 评分③ | 已完成 |
| ~~`wavetable_bank.v`~~ | ✅ **已实现**，已移入 `rtl/audio/wavetable_bank.v`（4 表合一 BSRAM）并接入 `inst.gprj` | 评分①（单波表只计 1 个振荡器） | 已完成 |
| ~~`vibrato_lfo.v`~~ | ✅ **已实现**，已移入 `rtl/audio/vibrato_lfo.v` 并接入 `inst.gprj`（颤音，5 Hz ±17 cent，长按 Key_2 的 fx 1/3/5/7 档）| 拓展②（≥3 维表情）| 已完成 |
| ~~`fx_echo.v`~~ | ✅ **已实现**，已移入 `rtl/audio/fx_echo.v` 并接入 `inst.gprj`（8192×16 BSRAM，124.4 ms，fx 2/3/6/7 档）| 拓展②（板内延迟）| 已完成 |
| `spectrum.v` | 实时频谱柱状图（8 点 DFT 或 8 带滤波器组） | 拓展③（实时频谱） | 1 天 |
| `velocity_sense.v` | 力度检测接口 | 拓展②（力度） | 需硬件支持 |

## 插入方式（以 `vibrato_lfo.v` 为例）

1. 在 `rtl/top/top_inst.v` 里加一行例化，把输出接到目标模块的输入；
2. 把 `rtl/_reserved/xxx.v` 移到对应板块目录（如 `rtl/audio/`）；
3. 在 `inst.gprj` 的 `<FileList>` 加一行：
   `<File path="rtl/audio/xxx.v" type="file.verilog" enable="1"/>`；
4. 在 `scripts/run_all_sim.ps1` 的 `$RTL` 和 `scripts/sim.ps1` 的 `$rtl` 里
   加上同一个路径；
5. 跑 `scripts\run_all_sim.ps1` 确认九个平台仍然全绿，再
   `scripts\build_inst.ps1` 出位流。

> **P0 的实战教训（务必先看）**：`test_mode.v` 第一版用 `output wire` + `assign`
> 组合选通，那 1 级 mux 正好串进 `note → inc_lut → <<oct` 这条最紧路径，
> Fmax 从 119.185 掉到 **108.850 MHz**（只剩 0.8% 余量）。改成 `reg` 输出、
> 在模块内打一拍后回到 119.647 MHz。**新功能凡是选通/旁路已有信号，一律先打拍。**
>
> **P3 的反面好消息**：`wavetable_bank.v` 把 4 张表合成一块 **BSRAM 同步读**，
> 替掉了原来贴得较紧的组合 ROM 路径，Fmax 反而从 119.647 升到 **124.043 MHz**。
> 所以"加功能必然掉时序"不是绝对的——换成同步读的存储体经常是净收益。

## 注意

- **不要**把它们一次性全加进 gprj“先占位”。Gowin 对没被引用的模块可以
  优化掉，但顶层端口一旦增加就必须同步补 `.cst` 管脚，否则综合报
  `PR2017 unable to place`。一个一个来接，接一个验一个。
- `velocity_sense.v` 需要硬件先解决：TTP229 是二值输出，拿不到压力。
  可选路径是换成支持力度的触摸方案（如 FDC2214 电容数字转换器），
  或在键位下方加 FSR。**在硬件落实前不要实现它**，否则接口会白写。
