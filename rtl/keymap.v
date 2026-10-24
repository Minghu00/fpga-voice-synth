//=============================================================================
// keymap.v  --  TTP229 16 keys  ->  13 piano note gates + 3 function keys
//
//  Physical layout of the 4x4 TTP229 pad (as agreed in 交互方案_TTP229.md)
//
//      上排   TP0   TP1   TP2   TP3    ->  C#4  D#4  F#4  G#4
//      第二排 TP4   TP5   TP6   TP7    ->  C4   D4   E4   F4
//      第三排 TP8   TP9   TP10  TP11   ->  G4   A4   B4   C5
//      底排   TP12  TP13  TP14  TP15   ->  A#4  8ve- 音色 8ve+
//
//  Voice index == key index, so voice i plays the note that belongs to TPi.
//  The three function keys produce no sound (gate = 0) and act on rising
//  edges, once per audio sample:
//      TP13 : octave down  (clamped at 0)
//      TP15 : octave up    (clamped at 2, i.e. max 4x -- see inc_lut.v)
//      TP14 : cycle timbre (0 organ, 1 square, 2 saw, 3 triangle)
//=============================================================================
`timescale 1ns / 1ps

module keymap (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,              // one clk pulse per audio sample
    input  wire [15:0] key_raw,         // 1 = pressed
    output wire [15:0] gate,            // 1 = sounding note key
    output wire [5*16-1:0] note_flat,   // 16 x 5 bit note index
    output reg  [1:0]  oct,             // phase-increment left shift 0..2
    output reg  [1:0]  timbre
);

    // note index per key, packed as {key15, key14, ... key0}
    localparam [5*16-1:0] NOTE_TAB =
        { 5'd0,  5'd0,  5'd0,  5'd10,   // 15,14,13,12
          5'd12, 5'd11, 5'd9,  5'd7,    // 11,10, 9, 8
          5'd5,  5'd4,  5'd2,  5'd0,    //  7, 6, 5, 4
          5'd8,  5'd6,  5'd3,  5'd1 };  //  3, 2, 1, 0

    assign gate      = key_raw & 16'h1FFF;   // keys 0..12 sound, 13..15 are function keys
    assign note_flat = NOTE_TAB;

    reg [15:0] key_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_d  <= 16'd0;
            oct    <= 2'd0;
            timbre <= 2'd0;
        end else if (en) begin
            key_d <= key_raw;

            if (key_raw[15] && !key_d[15]) begin
                if (oct != 2'd2)
                    oct <= oct + 2'd1;
            end
            if (key_raw[13] && !key_d[13]) begin
                if (oct != 2'd0)
                    oct <= oct - 2'd1;
            end
            if (key_raw[14] && !key_d[14]) begin
                timbre <= timbre + 2'd1;
            end
        end
    end

endmodule
