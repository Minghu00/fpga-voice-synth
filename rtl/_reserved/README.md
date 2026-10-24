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
| `test_mode.v` | 现场测试模式：一键输出 N 路标称频率的独立谱峰 | **评分③**（现场频谱可数谱峰） | 半天 |
| `wavetable_bank.v` | 4 张不同波表，替代当前“1 张正弦表 + 4 个倍数分量” | 评分①（单波表只计 1 个振荡器） | 半天 |
| `vibrato_lfo.v` | 颤音 LFO（±N cent 正弦调制相位增量） | 拓展②（≥3 维表情） | 半天 |
| `fx_echo.v` | 板内延迟/混响（BSRAM 环形缓冲） | 拓展②（FPGA 内部混响/延迟/合唱） | 1 天 |
| `spectrum.v` | 实时频谱柱状图（8 点 DFT 或 8 带滤波器组） | 拓展③（实时频谱） | 1 天 |
| `velocity_sense.v` | 力度检测接口 | 拓展②（力度） | 需硬件支持 |

## 插入方式（以 `test_mode.v` 为例）

1. 在 `rtl/top/top_inst.v` 里加一行例化，把输出接到 `keymap8` 或
   直接旁路到 `osc_bank` 的 `note_flat`；
2. 把 `rtl/_reserved/test_mode.v` 移出到 `rtl/audio/`（或留在原地，路径
   写 `rtl/_reserved/test_mode.v` 也行）；
3. 在 `inst.gprj` 的 `<FileList>` 加一行：
   `<File path="rtl/audio/test_mode.v" type="file.verilog" enable="1"/>`；
4. 在 `scripts/run_all_sim.ps1` 的 `$RTL` 和 `scripts/sim.ps1` 的 `$rtl` 里
   加上同一个路径；
5. 跑 `scripts\run_all_sim.ps1` 确认七个平台仍然全绿，再
   `scripts\build_inst.ps1` 出位流。

## 注意

- **不要**把它们一次性全加进 gprj“先占位”。Gowin 对没被引用的模块可以
  优化掉，但顶层端口一旦增加就必须同步补 `.cst` 管脚，否则综合报
  `PR2017 unable to place`。一个一个来接，接一个验一个。
- `velocity_sense.v` 需要硬件先解决：TTP229 是二值输出，拿不到压力。
  可选路径是换成支持力度的触摸方案（如 FDC2214 电容数字转换器），
  或在键位下方加 FSR。**在硬件落实前不要实现它**，否则接口会白写。
