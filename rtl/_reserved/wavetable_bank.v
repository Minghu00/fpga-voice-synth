//=============================================================================
// wavetable_bank.v  --  多波表库（预留，未接入工程）
//
//  背景：赛题评分①说「单波表查表只计 1 个振荡器；加法合成按运算分量计」。
//  当前 osc_bank 用**同一张正弦表**取 1×/2×/3×/4× 四个相位，产出一组
//  固化的谐波叠加。严格按字面理解，这可能被算作「1 个波表 × 4 个相位读口」，
//  而不是「4 个独立振荡器」，存在被判 1 个的风险。
//
//  解决思路：给每个分量一张**不同内容**的表（正弦 / 三角 / 锯齿 / 方波，
//  或四种不同谐波配比的正弦），并在 osc_bank 里让分量 i 读第 i 张表。
//  这样每个分量都是「自己的波表 + 自己的相位累加器 + 自己的频率调控」，
//  满足评分①对独立发声单元的定义。
//
//  存储成本：一张 1024×16 表 = 16 Kbit。4 张 = 64 Kbit，GW2A-18 有
//  46 块 BSRAM（每块 18 Kbit 左右），当前设计只用 4 块，完全放得下。
//
//  实现要点：
//      1) 用 4 个 .mem 文件（sine_1024.mem / tri_1024.mem / saw_1024.mem /
//         sqr_1024.mem），各自 `$readmemh` 到独立 reg 数组。
//      2) 或者用 1 个 4096×16 的合并表，最高 2 位选择表号 —— 省一次比较，
//         但要注意 Gowin 对 4096 深度的推断（会占满 1 块 BSRAM 的 16 Kbit，
//         正好合适）。
//      3) 表内容必须是有符号二进制补码，且**峰值归一化到 ±32767**，否则
//         各分量的相对音量会失衡。
//
//  当前状态：骨架。返回 0，未被任何工程引用。
//=============================================================================
`timescale 1ns / 1ps

module wavetable_bank (
    input  wire        clk,
    input  wire [9:0]  addr,        // 0..1023 相位
    input  wire [1:0]  sel,         // 0=正弦 1=三角 2=锯齿 3=方波
    output reg  [15:0] data         // 有符号补码
);

    // TODO: 接入时把这里换成真正的表。
    //   reg [15:0] tbl_sine [0:1023];
    //   reg [15:0] tbl_tri  [0:1023];
    //   reg [15:0] tbl_saw  [0:1023];
    //   reg [15:0] tbl_sqr  [0:1023];
    //   initial begin
    //       $readmemh("rtl/audio/sine_1024.mem", tbl_sine);
    //       $readmemh("rtl/audio/tri_1024.mem",  tbl_tri);
    //       $readmemh("rtl/audio/saw_1024.mem",  tbl_saw);
    //       $readmemh("rtl/audio/sqr_1024.mem",  tbl_sqr);
    //   end
    //
    //   always @(posedge clk) begin
    //       case (sel)
    //           2'd0: data <= tbl_sine[addr];
    //           2'd1: data <= tbl_tri [addr];
    //           2'd2: data <= tbl_saw [addr];
    //           2'd3: data <= tbl_sqr [addr];
    //       endcase
    //   end
    //
    // 注意：4 个 case 分支会被综合成 4 个读口 + 1 个 mux，最好把它们
    // 放进同一个 always 里推成寄存器输出，避免 ROM→mux→乘法器 的长路径
    // （当前 Fmax 余量只有 119.185 / 108 ≈ 10%，加 mux 要重新看时序）。

    always @(posedge clk) begin
        data <= 16'd0;
    end

endmodule
