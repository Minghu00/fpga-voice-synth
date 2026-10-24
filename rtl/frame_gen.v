//=============================================================================
// frame_gen.v  --  audio sample frame clock generator
//
//  sys_clk = 108 MHz, FRAME_LEN = 2240 clk
//      -> fs   = 108e6 / 2240 = 48 214.2857 Hz
//      -> i2s  = 32 bits/frame (16-bit slots) , BCLK half period = 35 clk
//                32 * 2 * 35 = 2240  -> exactly one frame, zero drift
//
//  fc          : 0 .. FRAME_LEN-1, free running
//  sample_tick : single clk pulse at fc == 0   (one audio sample period)
//  osc_ph      : fc in [0 , 1024)      -> oscillator slots   (64 x 16 clk)
//  env_ph      : fc in [1024 , 1088)   -> envelope update    (16 x 4 clk)
//  mix_ph      : fc in [1088 , 1152)   -> voice mixdown      (16 x 4 clk)
//=============================================================================
`timescale 1ns / 1ps

module frame_gen #(
    parameter integer FRAME_LEN = 2240,     // clk per audio frame
    parameter integer OSC_END   = 1024,     // end of oscillator phase
    parameter integer ENV_END   = 1088,     // end of envelope phase
    parameter integer MIX_END   = 1152      // end of mixdown phase
)(
    input  wire clk,
    input  wire rst_n,
    output reg  [11:0] fc,
    output wire sample_tick,
    output wire osc_ph,
    output wire env_ph,
    output wire mix_ph
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fc <= 12'd0;
        else if (fc == FRAME_LEN-1)
            fc <= 12'd0;
        else
            fc <= fc + 12'd1;
    end

    assign sample_tick = (fc == 12'd0);
    assign osc_ph      = (fc <  OSC_END);
    assign env_ph      = (fc >= OSC_END) && (fc < ENV_END);
    assign mix_ph      = (fc >= ENV_END) && (fc < MIX_END);

endmodule
