//=============================================================================
// fx_echo.v  --  板内延迟 / 混响（预留，未接入工程）
//
//  目的：补赛题拓展②「FPGA 内部实现混响、延迟、合唱」。
//
//  最小可行方案是**单抽头反馈延迟**（用于「延迟」和「合唱」），
//  加大到 4 抽头、抽头间隔互质就是「混响」的简化版。
//
//      y[n] = x[n] + g * y[n - D]
//
//  D 取 30 ms 左右 = 48214.29 × 0.030 ≈ 1446 样本，用一块 BSRAM 存
//  2048×16 即可（GW2A-18 每块 BSRAM 约 18 Kbit，2048×16 = 32 Kbit，
//  占 2 块）。
//
//  三种效果的典型参数（fs = 48 214.29）：
//      延迟  D = 1446 (30 ms), g = 0.40
//      合唱  D = 964  (20 ms), g = 0.50, 且让 D 随时间 ±3 样本缓慢摆动
//      混响  4 个抽头 D = 1447 / 1811 / 2293 / 2777 (互质), g = 0.3..0.5
//
//  关键实现陷阱：
//    · **反馈路径里的乘法必须打拍**。y[n-D] × g → 加 x[n] → 写回，如果
//      三级都在同一个 always 的组合逻辑里，Fmax 会掉到 60 MHz 以下。
//      当前设计 108 MHz 下的余量只有约 10%，必须做成「读 → 乘（寄） →
//      加（寄） → 写」三级流水，并相应把抽头地址提前一拍。
//    · 反馈系数 g 必须 <1，且要做**软限幅**（tanh 或简单的 sat16），否则
//      会自激啸叫到满幅方波。
//    · 写回的是 y[n]（含直达声）还是只有反馈项，决定 g 的有效范围；
//      本文给的是「写回 y[n]」，所以 g=0.4 时不会累积爆炸。
//
//  当前状态：骨架。输出等于输入（直通），未被工程引用。
//=============================================================================
`timescale 1ns / 1ps

module fx_echo #(
    parameter integer DEPTH   = 2048,   // BSRAM 深度，2 的幂
    parameter integer DELAY   = 1446,   // 30 ms @ 48.214 kHz
    parameter integer GAIN_Q8 = 102      // 0.4 × 256
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,          // 一 clk 脉冲/样本（fs）
    input  wire               fx_on,       // 1 = 效果器开
    input  wire signed [15:0] x,           // 混音后、音量前的干声
    output reg  signed [15:0] y            // 加效果后的输出
);

    // TODO: 接入时实现。
    //   reg [15:0] mem [0:DEPTH-1];
    //   reg [10:0] wp;
    //   wire [10:0] rp = wp - DELAY[10:0];
    //
    //   always @(posedge clk) begin
    //       if (!rst_n) begin
    //           wp <= 11'd0; y <= 16'sd0;
    //       end else if (en && fx_on) begin
    //           // 三级流水：读 → 乘 → 加
    //           mem[wp] <= sat16($signed(x) + $signed(fb));
    //           wp      <= wp + 11'd1;
    //           y       <= sat16($signed(x) + $signed(fb));
    //       end
    //   end
    //
    // 直通版本，保证文件可编译：
    always @(posedge clk) begin
        if (!rst_n) y <= 16'sd0;
        else        y <= x;
    end

endmodule
