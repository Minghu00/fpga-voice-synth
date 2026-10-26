# Fmax 加固记录

> 时间：2026-10-26
> 起点：`slack +0.013 ns`（Fmax 108.153 MHz @ 108 MHz 约束，余量 0.14%）
> 终点：`slack +0.047 ns`（Fmax **108.551 MHz**，余量 0.43%）
>
> **后续（混响/合唱并入后重测）**：`slack +0.148 ns` → **Fmax 109.755 MHz**（余量 1.60%），
> Logic 4159/20736、Register 2100/16173、CLS 2773/10368、BSRAM 13/46、DSP 6/24 不变；
> `fx_echo` 已不在最差 25 条路径里，新的最差是 `u_lcd/mult_1586_s1 → u_lcd/slvl_x_0_s74`（0.148）
> 与 `u_mixer/mult_211_s2 → u_mixer/vp_lo_2_s`（0.173）。
> 结论：**工具已经在设计能力边界上**，想再要余量必须继续削组合逻辑深度，不是调工具参数能解决的。

---

## 1. 先把"哪条路径最慢"查清楚

Gowin 的 `inst.rpt.txt` **没有 Fmax**，时序只在 PnR 的工作目录里：

```
%TEMP%\inst_build\impl\pnr\inst.timing_paths      ← 前 40 条路径，纯文本
%TEMP%\inst_build\impl\pnr\inst_tr_content.html   ← 全量
```

`scripts/build_inst.ps1` 只回拷 `impl\*`，所以 `impl_inst/pnr/` 里看不到它。
`inst.timing_paths` 的格式是每块以 `=====` 开头，字段顺序：

```
SETUP / slack / required / 起始网络 / 4.311 / 4.543 / 中间网络 / ... / 末端网络
```

`required` 恒为 **13.536 ns**（108 MHz 周期 9.2593 ns + 时钟建立/偏斜），
第一条路径的 slack 就是全设计的最差余量。

### 修改前最差的 12 条

| # | slack | 起点 → 终点 |
|---|---|---|
| 1 | 0.013 | `u_spec/bctr_0_s12` → `u_spec/re_re_0_0_s0` |
| 2 | 0.028 | `u_spec/pctr_2_s0` → `u_spec/lvl_flat_17_s0` |
| 3 | 0.052 | `u_frame/fc_3_s0` → `u_mixer/raw_q_1_s0` |
| 4 | 0.151 | `u_spec/re_re_0_1_s0` → `u_spec/aim_q_30_s0` |
| 5 | 0.151 | `u_spec/re_re_0_1_s0` → `u_spec/aim_q_31_s0` |
| 6–7 | 0.23 | `u_spec/bctr_0_s12` → `u_spec/re_re_0_1_s0` |
| 8–9 | 0.236 | `u_spec/pctr_2_s0` → `u_spec/lvl_flat_16/48_s0` |
| 10 | 0.237 | `u_spec/bctr_0_s12` → `u_spec/re_re_0_1_s0` |
| 11 | 0.240 | `u_mixer/mult_180_s2` → `u_mixer/sum_r_20_s0` |
| 12 | 0.253 | `u_spec/pctr_2_s0` → `u_spec/lvl_flat_15_s0` |

**12 条里 10 条在 `spectrum16`**，而且全部围绕同一件事：**用 `bctr` / `pctr` 变址访问寄存器数组**。

```verilog
re[bctr] <= re[bctr] + pS;          // 16:1 读 mux + 32 位加
are_q <= |re[pctr]|;                // 16:1 读 mux + 取绝对值
lvl_flat[pctr*4 +: 4] <= lvl;       // 16:1 写译码 + 4 位变址
```

寄存器数组一旦被变址，综合器只能铺成宽 mux。**16:1 的 32 位读 mux 单独就吃掉约 9 ns 路由**——
不是逻辑延迟，是 16 组散落的触发器把线拉长了。

---

## 2. 改法一：`spectrum16` 改成旋转阵列

关键洞察：**这 16 个 bin 永远是按 0,1,2,…,15 的顺序访问的**（扫描一遍，发布再一遍），
所以数组可以**在访问者脚下旋转**——当前 bin 永远是 slot 0。

```verilog
wire [8:0] p_k   = ph[0];
wire [8:0] p_cos = ph[0] + NQUART[8:0];

wire signed [31:0] re_nx = re[0] + pS;     // 读 slot 0，无 mux
wire signed [31:0] im_nx = im[0] - pC;
wire        [8:0]  ph_nx = ph[0] + k1;

// 纯邻居布线：每一级取上一级，slot 15 接新累加值
if (rot_sw_c) begin
    for (b = 0; b < NBINS-1; b = b + 1) begin
        re[b] <= re[b+1];  im[b] <= im[b+1];  ph[b] <= ph[b+1];
    end
    re[NBINS-1] <= re_nx;  im[NBINS-1] <= im_nx;  ph[NBINS-1] <= ph_nx;
end
```

16 次旋转 = 一整圈，回到原位，所以下一轮扫描看到的还是原来的分布。
发布阶段同样旋转，**并且把 0 移进来**——这一下同时把累加器清零了，原来的变址清零也删掉了。

`msb_q[pctr]` 和 `lvl_flat[pctr*4+:4]` 换成两根移位寄存器：
`msb_sh`（80 位 = 16×5，最老的 bin 在最高位）和 `lvl_sh`（64 位 = 16×4）。

### 两个必须记住的坑

**坑 1：旋转选通必须是组合的。**
第一版写成 `rot_sw <= 1'b1;`（寄存器），旋转被推迟一拍，那时 `bctr` 已经自增，
`ph_nx` 加的是**下一个 bin** 的 k，每个 bin 都累加了邻居的频率——仿真全黑。

**坑 2：`lvl_sh` 的移位方向。**
`{lvl, lvl_sh[59:0]}` 是错的：它丢掉了**刚插入的最高 4 位**，`lvl_flat` 永远是 0。
必须 `{lvl, lvl_sh[63:4]}`。这个 bug 让 `tb_spectrum16` 6 项 FAIL、全部 level=0。

---

## 3. 改法二：`mixer16` 的 mux 地址先打一拍

`fc[5:2] → vmux → 16:1 × 16 位数据 mux` 串在一拍里 13.48 ns，
因为 8 个源寄存器散在 die 上。把 4 个 phase 全部用上（原来 phase 3 是空转）：

```
ph 0 : vm_q / vok_q <= v        （只算地址，落在贴着 mux 的触发器上）
ph 1 : raw_q / env_q <= raw_flat[vm_q]
ph 2 : prod <= raw_q * env_q
ph 3 : accum <= accum + (prod>>>16)
```

窗口仍是 4 clk/声部 × 16 = 64 clk，最后一个声部 ph3 在 fc≈1119，远早于窗口末 1151，
所以**一帧都不多花**。

---

## 4. 认清一件事：`slack ≈ +0.01` 是工具行为，不是设计极限

Gowin PnR 的默认优化目标是 **100 MHz**，在生成的工作脚本里能直接看到：

```
%TEMP%\inst_build\impl\pnr\cmd.do:
    -place_option 0
    -route_option 0
    -clock_route_order 0
    -correct_hold 1
    -route_maxfan 23
    -global_freq 100.000        ← 默认目标
```

只要 SDC 里的 108 MHz 一满足，它就停止优化，**所以无论 RTL 多快，报告的 slack 总是 ≈+0.01 ns**。
`Fmax = 108 × 9.2593 / (9.2593 − slack)`，这就是之前 "108.153 MHz" 的来历——它不是天花板，是收敛点。

想让工具真的往上顶，在 `tcl/build_inst.tcl` 里加：

```tcl
set_option -global_freq 118
```

实测 `cmd.do` 里变成 `-global_freq 118.000`。

**结果：slack 0.013 → 0.047 ns。** 只多了 0.034 ns —— 说明工具**顶不到 118 MHz**：
如果它真能跑到 118，slack 应该是 ≈0.78 ns。**设计本身就在 108.5 MHz 附近。**

---

## 5. 改完之后的路径分布（证明改对了地方）

| # | slack | 起点 → 终点 |
|---|---|---|
| 1 | 0.047 | `u_lcd/y_q_3_s0` → `u_lcd/nr_0_s0` |
| 2–3 | 0.243 | `u_spec/im[14]_im[14]_0_1_s` → `u_spec/are_q_23/27_s0` |
| 4–7 | 0.259 | `u_spec/im[14]_im[14]_0_0_s` → `u_spec/aim_q_28..31_s0` |
| 8 | 0.363 | `u_lcd/y_q_3_s0` → `u_lcd/nb_4_s0` |

`spectrum16` 从 **0.013 退到 0.243**（好了 18 倍），旋转阵列生效。
新的第一名是 **`lcd_scope` 的颜色判定链**：`y_q` 要穿过
`y<28 → y<164 → y<232 → y<240` 四级串联比较再加 x 的窗口判断才到 `nr`。

---

## 6. 综合结果

| 项目 | 加固前 | 加固后 |
|---|---|---|
| **Fmax** @ 108 MHz 约束 | 108.153 MHz | **108.551 MHz** |
| 最差 setup slack | +0.013 ns | **+0.047 ns** |
| 告警 | 0 | **0**（顺带修掉 1 条 `EX3791`）|
| Logic | 4118/20736 (20%) | **4181/20736 (21%)** |
| Register | 1892/16173 (12%) | **2097/16173 (13%)**（FF 2069 + I/O FF 28）|
| CLS | — | **2772/10368 (27%)** |
| I/O Port | 35/207 | **35/207 不变** |
| BSRAM | 15/46 | **13/46 (29%)** |
| DSP | — | **6/24 (25%)** |
| 位流 | — | `impl_inst/pnr/inst.fs` 7,264,154 B |

**35 个端口逐一核对，与基线完全一致**：

```
clk27 H11/0   rst_n T3/4    tp_scl P8/3   tp_sdo T8/3
i2s_bclk R8/3 i2s_lrclk T7/3 i2s_din T6/3 test_sw P6/3
key_btn T2/4  vup_sw D7/6   sw5_vol C7/6
dip[0..3] E9/6 E8/6 T4/4 T5/4
lcd_dclk R9/3 lcd_hs A15/7  lcd_vs D14/1 lcd_de E15/1
lcd_r[0..4] L9/3 N8/3 N9/3 N7/3 N6/3
lcd_g[0..5] D11/7 A11/7 B11/7 P7/3 R7/3 D10/7
lcd_b[0..4] B12/7 C12/7 B13/7 A14/7 B14/7
```

寄存器涨了 205 个，全部来自旋转阵列的 `msb_sh`/`lvl_sh` 移位寄存器和 `mixer16` 的 `vm_q`/`vok_q`——
这是**用资源换时序**，20736 个 LUT 里只用了 21%，划算。

---

## 7. 仿真回归

`scripts/run_all_sim.ps1`，**14 个平台全部 PASS**：

```
tb_i2s_tx    tb_audio_out  tb_adsr      tb_mixer16
tb_osc_bank  tb_wavetable  tb_ttp229_rx tb_test_mode
tb_fx_echo   tb_liss       tb_spectrum16 tb_spec_cont
tb_vib_path  tb_inst
```

关键的是这两个改造**没有改变任何可测行为**：

- `tb_spectrum16`：`bin3=15`、`bin2=13`、`bin10=15`（AGC 归一化）、双音 `bin2=15 / bin11=15 / bin6=3`，与改造前逐项一致
- `tb_spec_cont`：`lit bins = 8, loudest = bin 3 at level 15`，与改造前一致
- `tb_mixer16`：`07ff / 7ffe / 8000 / 0000 / 7fff / 03ff` 六项全对

---

## 8. 还能往哪走（如果还要余量）

当前瓶颈是 `lcd_scope` 的颜色判定链（`y_q_3 → nr`，0.047 ns）。两条路：

1. **把 y 分段改成并行译码**：现在是 `if (y<28) … else if (y<164) … else if (y<232) …` 的串联链。
   改成先算一个 3 位 `band` 并**提前一级寄存**，颜色级只比较 `band` 与常数，能省 3~4 级 LUT。
2. **给颜色级加一级流水**：颜色本来就跟着像素流水走，多打一拍等于图像右移 1/12 个像素，肉眼不可见。
   （风险：`hsync`/`vsync` 是从同一级 `x_q` 推出的，要一起移，否则行首会错位。）

两条都是纯增量改动，做完大概能到 115~120 MHz 量级。
在此之前，**108.5 MHz / +0.047 ns 是可交付状态**：14 平台全绿、0 告警、35 管脚未变。
