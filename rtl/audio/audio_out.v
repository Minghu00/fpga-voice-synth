//=============================================================================
// audio_out.v  --  final audio stage between the mixer and the I2S transmitter
//
//      mixer (Q15, -32768..32767)
//          |  * gain  (Q8, 128..4096  =  0.5x .. 16x)
//          |  + test tone (optional)
//          v  saturate
//      i2s sample (Q15)
//
//---------------------------------------------------------------------------
//  WHY THIS BLOCK EXISTS  (and why it was rewritten)
//
//  The mixer runs at MIX_SHIFT = 3 so that all eight voices at full scale
//  still fit in 16 bits:  8 * 32767 >> 3 = 32767.  The price is that a single
//  key only produces ~2047, i.e. -24 dBFS, which through a MAX98357 at 3.3 V
//  is far too quiet.  This block therefore applies the make-up gain AFTER the
//  mixer, so the mixer keeps its "never clips" property while an ordinary
//  one-or-two-finger performance comes back to a usable level.
//
//  THE BUG THAT MADE THE BOARD COMPLETELY SILENT
//  ---------------------------------------------
//  The first version of this file applied a SECOND >>SHIFT_HP (3 bits) before
//  the multiply, on the assumption that mix_in still carried the raw
//  8 x 32767 sum.  It does not: mixer16.v already shifts by MIX_SHIFT, so the
//  old gain chain was
//
//        one organ voice 16383  ->  /8 (mixer)  ->  2047
//                               ->  /8 (here)   ->   255
//                               ->  x40/256      ->    39
//
//  39 out of 32767 is -58 dBFS.  The I2S stream was perfectly well formed and
//  the panel showed a beautiful waveform, but nothing above the amplifier's
//  noise floor ever came out of it.  SHIFT_HP is now gone and the table below
//  starts at unity so the number the mixer produces is the number the DAC
//  sees, scaled by a gain the performer can actually hear.
//
//  The second half of the same failure was the mute input: it was wired to
//  Silicon Key_3, which the Dock pulls up to +1V5 through 10 k and only shorts
//  to GND while the button is down.  The line therefore idles HIGH, mute
//  latched on at power-up, and the DAC received a stream of zeros.  Mute is no
//  longer driven by a board key; that key is a volume-up button now.
//---------------------------------------------------------------------------
//  CONTROLS
//    vol_raw    4 bit index into the gain table below
//                 0:  128  ( 0.5x,  -6 dB)
//                 1:  192  (0.75x,  -2.5 dB)
//                 2:  256  (  1x ,   0 dB)
//                 3:  384  (1.5x ,  +3.5 dB)
//                 4:  512  (  2x ,  +6 dB)
//                 5:  768  (  3x ,  +9.5 dB)
//                 6: 1024  (  4x , +12 dB)   <- power-on default
//                 7: 1536  (  6x , +15.6 dB)
//                 8: 2048  (  8x , +18 dB)
//                 9: 3072  ( 12x , +21.6 dB)
//                10: 4096  ( 16x , +24 dB)
//              11..15: 4096  (clamped)
//              With the default index the single-voice -24 dBFS from the
//              mixer comes out at -12 dBFS, and four fingers at full scale
//              still have 6 dB of headroom before the limiter.
//    mute        1 = silent (hard 0), still clocking I2S.  Tied low in
//                top_inst.v; kept as a port so a future control can use it.
//    test_tone   1 = ignore the synth and emit a fixed mid-scale square
//                wave, so the whole I2S + amplifier path can be proved with
//                no touch input at all.  48 214 / 256 = 188.3 Hz.
//
//  The apply stage is pipelined (gain is registered) so the multiplier never
//  sits between a live switch input and the DAC.
//=============================================================================
`timescale 1ns / 1ps

module audio_out #(
    parameter integer TONE_DIV = 256        // sample divider for the test tone
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_tick,   // one clk pulse per audio frame (unused, kept for compatibility)
    input  wire        mix_ok,       // a new mixed word is on mix_in
    input  wire signed [15:0] mix_in,
    input  wire [3:0]  vol_raw,
    input  wire        mute,
    input  wire        test_tone,
    output reg  signed [15:0] sample,
    output reg         sample_tick  // 1 clk pulse: `sample` is valid
);

    //------------------------------------------------------------------
    // gain table, two clock stages (raw -> index -> gain) so the switch
    // inputs are not in the multiplier's path.
    // 13 bits, Q8: gain = gain_q / 256, range 0.5x .. 16x.
    //------------------------------------------------------------------
    reg [3:0]  v_idx;
    reg [12:0] gain_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            v_idx <= 4'd6;                    // 4x / +12 dB, a safe default
        else
            v_idx <= vol_raw;
    end

    always @(*) begin
        case (v_idx)
            4'd0:    gain_q = 13'd128;
            4'd1:    gain_q = 13'd192;
            4'd2:    gain_q = 13'd256;
            4'd3:    gain_q = 13'd384;
            4'd4:    gain_q = 13'd512;
            4'd5:    gain_q = 13'd768;
            4'd6:    gain_q = 13'd1024;
            4'd7:    gain_q = 13'd1536;
            4'd8:    gain_q = 13'd2048;
            4'd9:    gain_q = 13'd3072;
            default: gain_q = 13'd4096;
        endcase
    end

    //------------------------------------------------------------------
    // apply gain, registered multiply
    //
    //   mix_s is 16 bit SIGNED and is deliberately NOT truncated first --
    //   the old `wire signed [14:0] mix_hp = mix_s >>> SHIFT_HP` lost the
    //   top bit as soon as SHIFT_HP was allowed to be 0.
    //
    //   16 bit signed  x  14 bit signed (0..4096)  ->  30 bit product
    //   Q8 gain -> >> 8 restores Q15.
    //------------------------------------------------------------------
    wire signed [15:0] mix_s = mix_in;

    reg  signed [29:0] prod;
    reg         [3:0]  mute_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod   <= 30'sd0;
            mute_q <= 4'd0;
        end else if (mix_ok) begin
            prod   <= mix_s * $signed({1'b0, gain_q});
            mute_q <= {mute_q[2:0], mute};
        end
    end

    wire signed [29:0] prod_sh = prod >>> 8;

    //------------------------------------------------------------------
    // soft knee limiter
    //
    //  mixer16 normalises 8 voices to exactly full scale (MIX_SHIFT = 3), and
    //  this stage then applies 0.5x .. 16x on top.  With the power-up default
    //  of 4.0x the sum leaves the 16 bit range as soon as four voices are
    //  sounding at once (measured: organ clips at N = 5, the square timbre
    //  clips at N = 4).  Latch mode makes that easy to reach, and a hard
    //  clip is what the ear hears as a rough tremble: flattening the peaks of
    //  a chord generates difference tones between every pair of notes, and
    //  those beat against the chord.
    //
    //  A 2-segment limiter keeps the transfer curve continuous:
    //      |x| <= KNEE   ->  x
    //      |x| >  KNEE   ->  KNEE + (|x| - KNEE) / 8
    //  The slope steps 1 -> 1/8 instead of 1 -> 0, so far fewer sidebands are
    //  produced, and the output is bounded: the largest input this stage can
    //  ever see is 32767 * 4096 / 256 = 524272 ... in practice prod_sh for
    //  eight full-scale voices at 16x is 16383 * 16 = 262128, which maps to
    //  24576 + (262128-24576)/8 = 54240 -> still above 16 bit, so sat16()
    //  stays as the final hard stop for that extreme case.
    //------------------------------------------------------------------
    localparam signed [29:0] KNEE = 30'sd24576;      // 0.75 of full scale

    function signed [15:0] sat16;
        input signed [29:0] x;
        begin
            if (x > 30'sd32767)
                sat16 = 16'sh7FFF;
            else if (x < -30'sd32768)
                sat16 = 16'sh8000;
            else
                sat16 = x[15:0];
        end
    endfunction

    function signed [15:0] soft;
        input signed [29:0] x;
        reg   signed [29:0] ax;
        reg   signed [29:0] y;
        begin
            ax = x[29] ? -x : x;                     // magnitude
            if (ax <= KNEE)
                y = ax;                              // y is a magnitude, the
            else                                     // sign is restored below
                y = KNEE + ((ax - KNEE) >>> 3);      // 1/8 slope above knee
            soft = sat16(x[29] ? -y : y);
        end
    endfunction

    //------------------------------------------------------------------
    // test tone: mid-scale square, no touch input required
    //------------------------------------------------------------------
    reg [7:0] tdiv;
    reg       tlevel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdiv   <= 8'd0;
            tlevel <= 1'b0;
        end else if (mix_ok) begin
            tdiv <= tdiv + 8'd1;
            if (tdiv == TONE_DIV[7:0] - 8'd1)
                tlevel <= ~tlevel;
        end
    end

    wire signed [15:0] tone = tlevel ? 16'sh2000 : -16'sh2000;   // -12 dBFS

    //------------------------------------------------------------------
    // output select on sample_tick
    //------------------------------------------------------------------
    reg tick_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample      <= 16'sd0;
            tick_d      <= 1'b0;
        end else begin
            tick_d <= mix_ok;
            if (tick_d) begin
                if (test_tone)
                    sample <= tone;
                else if (mute | mute_q[3])
                    sample <= 16'sd0;
                else
                    sample <= soft(prod_sh);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample_tick <= 1'b0;
        else
            sample_tick <= tick_d;
    end

endmodule
