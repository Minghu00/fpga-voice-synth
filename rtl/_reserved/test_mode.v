//=============================================================================
// test_mode.v  --  现场测试模式（预留，未接入工程）
//
//  目的：满足赛题评分③ —— 「现场能用测试模式输出多路不同频率，频谱看到
//  对应数量独立谱峰，RTL 佐证无预录播放」。
//
//  行为设想：
//      test_en = 1 时，忽略触摸键盘，直接把 VOICES 个声部强制指向一组
//      固定的音名，且每个声部只开 1 个加法分量（纯正弦）。这样频谱上
//      正好能数出 VOICES 根独立谱峰，且频率是已知标称值，可用频率计核对。
//
//  为什么每个声部只留 1 个分量：
//      当前 osc_bank 的 4 个分量是同频的 1×/2×/3×/4× 谐波。如果测试模式
//      照旧开 4 个分量，一个声部就占 4 根谱峰，评委数出来的数量会是
//      VOICES×4 而不是 VOICES，反而容易被质疑「虚报振荡器数量」。
//      测试模式要的是「干净可数」，所以这里显式压成单分量。
//
//  插入点（见 rtl/_reserved/README.md）：
//      test_mode 的输出直接替换 keymap8 的两个输出：
//          gate      -> osc_bank 装载门控
//          note_flat -> osc_bank 的 note_flat
//      在 top_inst 里二选一：
//          .note_flat(test_en ? test_note : key_note)
//
//  当前状态：骨架。输出常量 0，未被任何工程引用。
//=============================================================================
`timescale 1ns / 1ps

module test_mode #(
    parameter integer VOICES = 8,
    // 每个声部的标称音名（5 位索引，见 inc_lut.v 的音名表）。
    // 默认给一组五声音阶，频谱上间隔明显、不易混叠。
    parameter [5*VOICES-1:0] NOTE_SET = {
        5'd0,  5'd2,  5'd4,  5'd7,
        5'd9,  5'd12, 5'd14, 5'd16
    }
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 test_en,     // 1 = 现场测试模式
    output wire [VOICES-1:0]    gate,        // 全部同时开
    output wire [5*VOICES-1:0]  note_flat    // 固定音名
);

    // TODO: 接入时在这里实现。
    //   1) gate 全部拉 1（或按需只开前 N 路，用参数控制）
    //   2) note_flat 直接输出 NOTE_SET
    //   3) test_en = 0 时把输出交给 keymap8（由 top_inst 做二选一，本模块不管）
    //
    // 保持输出为常量，是为了让这个文件现在就能通过 iverilog 编译检查。
    assign gate      = {VOICES{1'b0}};
    assign note_flat = {5*VOICES{1'b0}};

endmodule
