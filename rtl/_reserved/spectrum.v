//=============================================================================
// spectrum.v  --  实时频谱柱状图（预留，未接入工程）
//
//  目的：补赛题拓展③「硬件实时生成实时频谱显示」。当前屏上已有波形示波器
//  （lcd_scope.v 的 y48..111 区）和包络柱（y112..175），缺的是**频域**显示。
//
//  现实约束：480×272 屏、8 位柱高，做一个 16 点 Goertzel 就够看了，真做
//  1024 点 FFT 反而浪费 —— GW2A-18 的 24 个 DSP 里只有 3 个在用，但
//  BSRAM 只剩 42 块，而且 Fmax 余量已经不宽裕。
//
//  两种实现路线：
//    A. **Goertzel**（推荐）：每个频带一个二阶 IIR，只算「该频带有多少能量」，
//       不关心相位。8 个频带 = 8 个乘累加，时分复用一个 DSP 即可。
//           s[n] = x[n] + 2cos(w)·s[n-1] - s[n-2]
//           |X|² = s[N-1]² + s[N-2]² - 2cos(w)·s[N-1]·s[N-2]
//       频带中心取音阶的几个八度（如 130/260/520/1k/2k/4k/8k/16k Hz）。
//    B. **8 通道带通 + 包络**：更省资源，但分辨率差，频带间会漏。
//
//  显示方式：直接复用 lcd_scope.v 的柱状绘制逻辑（倒数乘法算列索引），
//  只是把数据源从 env_flat 换成 8 个频带能量。
//
//  关键实现陷阱：
//    · Goertzel 的 s[n-1]/s[n-2] 必须**限幅**，否则高 Q 值下会数值爆炸。
//      建议用 24 位累加器 + 饱和。
//    · 2cos(w) 是常数系数，用 Q14 定点（例如 w 对应 1 kHz 时
//      2cos(2π·1000/48214.29) = 1.99148 → 0x7F9E）。
//    · 每个频带要按 N 个样本出一次结果，N 取 1024 时频率分辨率
//      = 48214.29/1024 = 47 Hz，对音乐足够。
//
//  当前状态：骨架。输出全 0，未被工程引用。
//=============================================================================
`timescale 1ns / 1ps

module spectrum #(
    parameter integer NBANDS = 8,
    parameter integer NFFT   = 1024        // 每 N 个样本更新一次
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,        // 一 clk 脉冲/样本（fs）
    input  wire signed [15:0]      x,         // 混音信号
    output reg  [8*NBANDS-1:0]     mag,       // 每频带 8 位对数幅度
    output reg                     mag_ok     // 一 clk 脉冲：mag 有效
);

    // TODO: 接入时实现 8 路 Goertzel。
    //   reg signed [23:0] s1 [0:NBANDS-1];
    //   reg signed [23:0] s2 [0:NBANDS-1];
    //   reg [9:0] cnt;
    //   // 每个样本对每个频带做一次二阶递推（按时隙复用乘法器）
    //   // cnt 到 NFFT-1 时算出 |X|²，取 log2 收缩成 8 位，置 mag_ok
    //
    // 直通占位，保证文件可编译：
    always @(posedge clk) begin
        if (!rst_n) begin
            mag    <= {8*NBANDS{1'b0}};
            mag_ok <= 1'b0;
        end else begin
            mag    <= {8*NBANDS{1'b0}};
            mag_ok <= 1'b0;
        end
    end

endmodule
