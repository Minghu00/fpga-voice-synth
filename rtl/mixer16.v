//=============================================================================
// mixer16.v  --  N-voice mixdown with per-voice envelope + hard limiter
//
//  Runs inside the 64 clk "mix" window of the audio frame (fc 1088..1151),
//  four clocks per voice:
//      ph 0 : raw_q / env_q  <= voice v            (mux only)
//      ph 1 : prod           <= raw_q * env_q      (18x18 DSP)
//      ph 2 : accum          <= accum + (prod>>>16)
//                             at the last voice, latch the limited result
//      ph 3 : spare
//
//  Scaling
//      raw : Q15 signed, +-32767 per voice (4 harmonics already sum-shifted)
//      env : Q16 unsigned, 0 .. 65535  (65535 = 1.0)
//      prod>>>16 : back to Q15
//      accum : VOICES voices -> +-32767*VOICES  (23 bit is plenty)
//      out = accum >>> MIX_SHIFT, then saturated to 16 bit
//
//  MIX_SHIFT is chosen by the caller so that all voices at full scale reach
//  exactly full scale without clipping (扩展-③ spectrum test needs clean,
//  unclipped spectral peaks, so no clipping distortion is allowed at all):
//      VOICES = 16 -> MIX_SHIFT = 4     (16 * 32767 >> 4 = 32767)
//      VOICES =  8 -> MIX_SHIFT = 3     ( 8 * 32767 >> 3 = 32767)
//
//  NOTE ON THE WINDOW: the window is 64 clk wide, i.e. 16 voice slots, so a
//  design with VOICES < 16 must mask the tail off.  The "last voice" test
//  used to be written as  v == VOICES-1  with a 4 bit v against an integer
//  localparam; that comparison is self-determined at 32 bits, so
//  VOICES-1 = 7 could never equal the 4 bit v when v reached 15 and the
//  mixdown result was never latched -- silicon came out silent while the
//  waveform RAM (fed straight from the mix node) looked perfectly fine.
//  out_ok now drives both the mixer latch and the I2S frame loader, so a
//  stuck mixer can never quietly produce a DC-only output again.
//=============================================================================
`timescale 1ns / 1ps

module mixer16 #(
    parameter integer VOICES    = 16,
    parameter integer MIX_SHIFT = 4
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [11:0] fc,
    input  wire        mix_ph,                  // fc in [1088,1152)
    input  wire [16*VOICES-1:0] raw_flat,
    input  wire [16*VOICES-1:0] env_flat,
    output reg  [15:0] out,                     // signed, to the volume stage
    output wire        out_ok                   // one clk pulse per frame
);

    wire [3:0] v  = fc[5:2];        // voice index inside the mix window
    wire [1:0] ph = fc[1:0];

    wire [3:0] v_last = VOICES[3:0] - 4'd1;     // sized compare (see note above)

    // The mix window is always 64 clk wide, so with fewer than 16 voices the
    // tail of the window must be masked off -- otherwise v would run past the
    // end of raw_flat / env_flat.  vmux keeps the mux address legal.
    wire       v_ok = (v < VOICES);
    wire [3:0] vmux = v_ok ? v : 4'd0;

    // Voice selection and the two 16-way muxes get their own clock, so the
    // multiplier never sees a mux in front of it.
    reg  signed [15:0] raw_q;
    reg         [15:0] env_q;

    wire signed [15:0] raw_x = raw_flat[vmux*16 +: 16];
    wire        [15:0] env_x = env_flat[vmux*16 +: 16];

    reg  signed [31:0] prod;
    reg  signed [22:0] accum;

    wire signed [31:0] prod_s = prod;
    wire signed [16:0] vp     = prod_s >>> 16;
    wire signed [22:0] fin    = accum + vp;

    // latched on the last voice of the window, one clk after ph==2
    reg        last_q;
    reg  signed [22:0] sum_q;
    assign out_ok = last_q;

    function [15:0] sat16;
        input signed [31:0] x;
        begin
            if (x > 32'sd32767)
                sat16 = 16'h7FFF;
            else if (x < -32'sd32768)
                sat16 = 16'h8000;
            else
                sat16 = x[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod   <= 32'sd0;
            accum  <= 23'sd0;
            out    <= 16'd0;
            raw_q  <= 16'sd0;
            env_q  <= 16'd0;
            last_q <= 1'b0;
            sum_q  <= 23'sd0;
        end else begin
            last_q <= 1'b0;
            if (mix_ph && v_ok) begin
                case (ph)
                    2'd0: begin
                        raw_q <= raw_x;
                        env_q <= env_x;
                    end
                    2'd1: prod <= raw_q * $signed({1'b0, env_q});
                    default: begin              // ph == 2 (and the spare cycle 3)
                        if (ph == 2'd2) begin
                            accum <= (v == 4'd0) ? vp : fin;
                            if (v == v_last) begin
                                sum_q <= (v == 4'd0) ? vp : fin;
                                last_q <= 1'b1;     // -> out_ok
                            end
                        end
                    end
                endcase
            end
            if (last_q)
                out <= sat16(sum_q >>> MIX_SHIFT);
        end
    end

endmodule
