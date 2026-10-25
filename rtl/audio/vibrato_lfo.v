//=============================================================================
// vibrato_lfo.v  --  5 Hz sine LFO producing a tiny multiplicative detune
//
//  赛题拓展② "≥3 维表情（力度 / 滑音 / 颤音）" 里的「颤音」维度.
//
//  Why MULTIPLICATIVE and not additive
//  -----------------------------------
//  The obvious implementation is  inc' = inc + delta  with a fixed delta.
//  That detunes low notes far too much and high notes far too little: +-30
//  cent means "multiply the frequency by 1.0176", which is +4.6 Hz at C4 but
//  +18.4 Hz at C6.  A fixed delta would give a barely audible wobble on bass
//  and a siren on treble.  So the LFO emits a small signed integer `d` and
//  the oscillator bank applies
//
//          inc' = inc + (inc >> 10) * d        (Q10, so d = 18 is +1.76 %)
//
//  which is a constant musical interval at every pitch.
//
//  Implementation
//  --------------
//  A 24-bit phase accumulator stepped once per audio sample.  5.0004 Hz at
//  fs = 48 214.2857 Hz (108 MHz / 2240).  The top bits index a 32-entry
//  QUARTER sine table that is mirrored and sign-flipped, so the whole ROM is
//  32 x 6 bit = 192 bit of LUT, no BSRAM and no `$readmemh`.
//
//      ph[23]      half   : 0 = first  180 deg, 1 = second 180 deg
//      ph[22]      quarter: 0 = rising, 1 = falling
//      ph[21:17]   32 steps inside the quarter
//
//  `d` is signed, range -DEPTH .. +DEPTH.  d = 0 disables the vibrato
//  completely, which is what makes the "off" mode bit-identical to P3.
//=============================================================================
`timescale 1ns / 1ps

module vibrato_lfo #(
    parameter integer PH_INC = 1740,    // 24-bit, 5.0004 Hz at 48 214.2857 Hz
    parameter integer DEPTH  = 18       // +-18/1024 = +-30 cent
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,             // one clk pulse per audio sample
    input  wire        on,
    output reg  signed [5:0] d,        // Q10 detune, 0 when off
    output reg  signed [5:0] d_abs     // |d|, for the on-screen level meter
);

    localparam signed [6:0] DMAX  = DEPTH[6:0];
    localparam signed [6:0] DMIN  = -DEPTH[6:0];

    //------------------------------------------------------------------
    // quarter sine, 32 entries, round(DEPTH * sin(pi/2 * i/32))
    //   with DEPTH = 18 the peak is 18/1024 = 1.76 % = 30.2 cent
    //------------------------------------------------------------------
    function [5:0] qsin;
        input [4:0] i;
        begin
            case (i)
                5'd0:  qsin = 6'd0;   5'd1:  qsin = 6'd1;
                5'd2:  qsin = 6'd2;   5'd3:  qsin = 6'd3;
                5'd4:  qsin = 6'd4;   5'd5:  qsin = 6'd4;
                5'd6:  qsin = 6'd5;   5'd7:  qsin = 6'd6;
                5'd8:  qsin = 6'd7;   5'd9:  qsin = 6'd8;
                5'd10: qsin = 6'd8;   5'd11: qsin = 6'd9;
                5'd12: qsin = 6'd10;  5'd13: qsin = 6'd11;
                5'd14: qsin = 6'd11;  5'd15: qsin = 6'd12;
                5'd16: qsin = 6'd13;  5'd17: qsin = 6'd13;
                5'd18: qsin = 6'd14;  5'd19: qsin = 6'd14;
                5'd20: qsin = 6'd15;  5'd21: qsin = 6'd15;
                5'd22: qsin = 6'd16;  5'd23: qsin = 6'd16;
                5'd24: qsin = 6'd17;  5'd25: qsin = 6'd17;
                5'd26: qsin = 6'd17;  5'd27: qsin = 6'd17;
                5'd28: qsin = 6'd18;  5'd29: qsin = 6'd18;
                5'd30: qsin = 6'd18;
                default: qsin = 6'd18;
            endcase
        end
    endfunction

    reg [23:0] ph;

    // fold the quarter wave into a full sine
    wire        half = ph[23];
    wire [4:0]  qi   = ph[22] ? (5'd31 - ph[21:17]) : ph[21:17];
    wire [5:0]  mag  = qsin(qi);
    wire signed [6:0] s_mag = half ? -$signed({1'b0, mag}) : $signed({1'b0, mag});

    // clamp to +-DEPTH (the table peak is DEPTH already, so this is belt and braces)
    wire signed [6:0] s_lim = (s_mag > DMAX) ? DMAX :
                              (s_mag < DMIN) ? DMIN :
                              s_mag;

    // |s_lim| without part-selecting an expression (Verilog-2001 forbids that)
    wire signed [6:0] s_pos = s_lim[6] ? -s_lim : s_lim;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph    <= 24'd0;
            d     <= 6'sd0;
            d_abs <= 6'sd0;
        end else if (en) begin
            ph <= ph + PH_INC[23:0];
            // `on` is sampled at the same instant as the phase step, so the
            // output is a clean sine that simply collapses to 0 when off.
            d     <= on ? s_lim[5:0] : 6'sd0;
            d_abs <= on ? s_pos[5:0] : 6'sd0;
        end
    end

endmodule
