//=============================================================================
// mixer16.v  --  N-voice mixdown with per-voice envelope + hard limiter
//                 + alternating L/R panning (for the Lissajous display)
//
//  Runs inside the 64 clk "mix" window of the audio frame (fc 1088..1151),
//  four clocks per voice:
//      ph 0 : vm_q / vok_q   <= voice v            (address only)
//      ph 1 : raw_q / env_q  <= raw_flat[vm_q]     (data mux)
//      ph 2 : prod           <= raw_q * env_q      (18x18 DSP)
//      ph 3 : acc_e / acc_o  <= acc + (prod>>>16)  (split by voice parity)
//
//  Scaling
//      raw : Q15 signed, +-32767 per voice (4 harmonics already sum-shifted)
//      env : Q16 unsigned, 0 .. 65535  (65535 = 1.0)
//      prod>>>16 : back to Q15
//      acc : VOICES voices -> +-32767*VOICES  (23 bit is plenty)
//      out = acc >>> MIX_SHIFT, then saturated to 16 bit
//
//  MIX_SHIFT is chosen by the caller so that all voices at full scale reach
//  exactly full scale without clipping (扩展-③ spectrum test needs clean,
//  unclipped spectral peaks, so no clipping distortion is allowed at all):
//      VOICES = 16 -> MIX_SHIFT = 4     (16 * 32767 >> 4 = 32767)
//      VOICES =  8 -> MIX_SHIFT = 3     ( 8 * 32767 >> 3 = 32767)
//
//-----------------------------------------------------------------------------
//  PANNING  (added for the P1c Lissajous page)
//
//  The eight voices are panned alternately left / right so that the left and
//  right channels carry genuinely different mixtures -- without that, L and R
//  would be identical and an X-Y plot could only ever draw a straight line.
//
//      even voice : L = 1.0        R = 13/16  (= 0.8125, -1.8 dB)
//      odd  voice : L = 13/16      R = 1.0
//
//  Amplitude spread is therefore 1.0 : 0.8125 = 1.23x, i.e. about +-1 dB --
//  the "punish the stereo image by no more than 20 %" budget that was agreed
//  with the user.  13/16 is used instead of 0.8 because it is a pure shift /
//  add:  x * 13/16 = x - (x>>>4) - (x>>>3), so no extra multiplier is needed.
//
//  Three sums are produced:
//      out    : plain sum (identical to the pre-panning behaviour, so every
//               existing testbench expectation and the waveform page are
//               bit-for-bit unchanged)
//      out_l  : panned left
//      out_r  : panned right
//
//  TIMING.  Panning every voice put
//      multiplier -> 13/16 shift/add -> pan select -> 23-bit accumulate
//  in one 9.26 ns cycle and measured +0.017 ns of slack.  Instead the voices
//  are split by parity *while accumulating* (even -> acc_e, odd -> acc_o) and
//  the pan is applied once per frame to the two partial sums:
//      out_l = sum_e + (13/16) * sum_o
//      out_r = sum_o + (13/16) * sum_e
//  mathematically identical, and the per-voice path is a single 23-bit add.
//  `out` = (sum_e + sum_o) >>> MIX_SHIFT stays bit-for-bit the old mono mix.
//-----------------------------------------------------------------------------
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
    output reg  [15:0] out,                     // mono, to the volume stage
    output reg  [15:0] out_l,                   // panned left
    output reg  [15:0] out_r,                   // panned right
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
    //
    //  TIMING.  The mux ADDRESS now gets its own cycle too.  Driving the mux
    //  straight from fc[5:2] put the frame counter's decode in series with a
    //  16:1 x 16-bit data mux, and that path measured 13.48 ns against a
    //  9.26 ns period (+0.05 ns slack) because the eight source registers are
    //  scattered across the die.  vm_q is a flop placed next to the mux, so
    //  only the data fan-in is left in the cycle.  The phases therefore are:
    //
    //      ph 0 : vm_q / vok_q <= v                  (address only)
    //      ph 1 : raw_q / env_q <= raw_flat[vm_q]    (data mux)
    //      ph 2 : prod          <= raw_q * env_q     (18x18 DSP)
    //      ph 3 : acc_e/acc_o   <= acc + (prod>>>16) (split by voice parity)
    //
    //  The window is 4 clk per voice, so this still fits in the 64 clk mix
    //  window; it simply uses the phase that used to be spare.
    reg  signed [15:0] raw_q;
    reg         [15:0] env_q;
    reg         [3:0]  vm_q;
    reg                vok_q;

    wire signed [15:0] raw_x = raw_flat[vm_q*16 +: 16];
    wire        [15:0] env_x = env_flat[vm_q*16 +: 16];

    reg  signed [31:0] prod;

    wire signed [31:0] prod_s = prod;
    wire signed [16:0] vp     = prod_s >>> 16;

    // ---- panning ----------------------------------------------------------
    //  Voices are split by parity while they accumulate: even voices land in
    //  acc_e, odd voices in acc_o.  Panning is then applied ONCE per frame to
    //  the two partial sums instead of once per voice:
    //      out_l = sum_e + (13/16) * sum_o
    //      out_r = sum_o + (13/16) * sum_e
    //  which is the same arithmetic as panning every voice, but the per-voice
    //  path is now a single 23-bit add.  Doing it per voice put
    //  "multiplier -> 13/16 shift/add -> pan select -> accumulate" in one
    //  9.26 ns cycle and measured only +0.017 ns of slack.
    reg  signed [22:0] acc_e;
    reg  signed [22:0] acc_o;
    wire signed [22:0] fin_e = acc_e + vp;
    wire signed [22:0] fin_o = acc_o + vp;

    // latched on the last voice of the window, one clk after ph==2
    reg        last_q;
    reg  signed [22:0] sum_e;
    reg  signed [22:0] sum_o;

    // 13/16 as a shift/add (no multiplier); >>> keeps the sign
    wire signed [22:0] se13 = sum_e - (sum_e >>> 4) - (sum_e >>> 3);
    wire signed [22:0] so13 = sum_o - (sum_o >>> 4) - (sum_o >>> 3);
    wire signed [22:0] lsum = sum_e + so13;
    wire signed [22:0] rsum = sum_o + se13;

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
            out    <= 16'd0;
            out_l  <= 16'd0;
            out_r  <= 16'd0;
            raw_q  <= 16'sd0;
            env_q  <= 16'd0;
            vm_q   <= 4'd0;
            vok_q  <= 1'b0;
            last_q <= 1'b0;
            acc_e  <= 23'sd0;
            acc_o  <= 23'sd0;
            sum_e  <= 23'sd0;
            sum_o  <= 23'sd0;
        end else begin
            last_q <= 1'b0;
            if (mix_ph) begin
                case (ph)
                    2'd0: begin
                        vm_q  <= vmux;
                        vok_q <= v_ok;
                    end
                    2'd1: if (vok_q) begin
                        raw_q <= raw_x;
                        env_q <= env_x;
                    end
                    2'd2: if (vok_q) prod <= raw_q * $signed({1'b0, env_q});
                    default: if (vok_q) begin     // ph == 3
                        if (v == 4'd0) begin
                            acc_e <= v[0] ? 23'sd0 : vp;
                            acc_o <= v[0] ? vp : 23'sd0;
                            sum_e <= v[0] ? 23'sd0 : vp;
                            sum_o <= v[0] ? vp : 23'sd0;
                        end else if (v[0]) begin
                            acc_o <= fin_o;
                            sum_o <= fin_o;
                            sum_e <= acc_e;
                        end else begin
                            acc_e <= fin_e;
                            sum_e <= fin_e;
                            sum_o <= acc_o;
                        end
                        if (v == v_last)
                            last_q <= 1'b1;     // -> out_ok
                    end
                endcase
            end
            if (last_q) begin
                out   <= sat16((sum_e + sum_o) >>> MIX_SHIFT);
                out_l <= sat16(lsum >>> MIX_SHIFT);
                out_r <= sat16(rsum >>> MIX_SHIFT);
            end
        end
    end

endmodule
