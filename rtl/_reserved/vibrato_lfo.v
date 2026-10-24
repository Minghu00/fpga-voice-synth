//=============================================================================
// vibrato_lfo.v  --  颤音 LFO（预留，未接入工程）
//
//  目的：补赛题拓展②「≥3 维表情（力度、滑音、颤音）」。当前已有
//        · 选音（8 键位置）
//        · 触发（按下/松开）
//        · 滑音（划过相邻键位 → note_flat 变化，inc 跟随）
//        · 力度 —— 拿不到（TTP229 二值输出）
//        颤音就是最省事、最能补上「第 3 维」的一项。
//
//  原理：对相位增量做乘性调制（不是加性！）。加性调制会让音高随八度
//  线性偏移，低音区颤不起来、高音区颤过头；乘性调制才是听觉上等幅的。
//
//      inc_out = inc_in * (1024 + lfo_val) >> 10
//
//  其中 lfo_val 在 ±DEPTH 之间按正弦摆动，DEPTH=1024*0.01 ≈ 10 就是 ±1%
//  ≈ ±17 cent，是比较明显的颤音；专业歌手的颤音在 ±15..25 cent。
//
//  LFO 频率：4..7 Hz，取 5 Hz 最常见。fs=48214.29，所以一个 LFO 周期
//  = 48214.29/5 ≈ 9643 个样本。用 14 位计数器 + 小正弦表（或三角波）即可。
//
//  关键实现陷阱：
//    · 调制必须作用在**已经做过八度移位的最终 inc**上，不能在 inc_lut 之前，
//      否则八度切换时颤音深度会跳变 2 倍。
//    · lfo_val 必须是**有符号**的，且 1024+lfo_val 不能过零（DEPTH<1024），
//      否则会出现相位倒转的爆音。
//    · 每个声部共用一个 LFO 相位（所有音同步颤）听感更自然；如果要模拟
//      合唱效果，给每个声部加一个随机初相即可。
//
//  当前状态：骨架。深度的乘加未实现，输出等于输入（直通），未被工程引用。
//=============================================================================
`timescale 1ns / 1ps

module vibrato_lfo #(
    parameter integer LFO_DIV = 9643,   // fs / LFO 频率，默认 5 Hz
    parameter integer DEPTH   = 10      // ±1% ≈ ±17 cent
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,          // 一 clk 脉冲/样本（fs）
    input  wire               vib_on,      // 1 = 颤音开
    input  wire signed [31:0] inc_in,      // 来自 osc_bank 的最终相位增量
    output reg  signed [31:0] inc_out      // 调制后
);

    // TODO: 接入时实现。
    //   reg [13:0] lfo_ph;
    //   always @(posedge clk)
    //       if (!rst_n)                       lfo_ph <= 14'd0;
    //       else if (en && vib_on)            lfo_ph <= lfo_ph + 14'd1;
    //
    //   wire signed [10:0] lfo_val = ...      // 三角波或查表，范围 ±DEPTH
    //   wire signed [21:0] mod     = 22'sd1024 + lfo_val;
    //   wire signed [52:0] prod    = inc_in * mod;
    //
    //   always @(posedge clk)
    //       if (!rst_n) inc_out <= 32'sd0;
    //       else        inc_out <= prod[41:10];   // >>10
    //
    // 直通版本，保证文件可编译：
    always @(posedge clk) begin
        if (!rst_n) inc_out <= 32'sd0;
        else        inc_out <= inc_in;
    end

endmodule
