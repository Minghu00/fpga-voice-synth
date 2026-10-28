//=============================================================================
// keymap8.v  --  8-key TTP229 pad  ->  8 piano gates + octave / timbre / volume
//
//  The TTP229 module sends 8 bits (it is the 8-key variant of the board), and
//  we use those 8 pads as a polyphonic keyboard.  Voice index == key index,
//  so voice i always plays the note that belongs to TPi.
//
//  ONE PAD LAYOUT: an ascending C major arpeggio (see PAD LAYOUT below)
//
//      TP0  TP1  TP2  TP3  TP4  TP5  TP6  TP7
//       C4   E4   G4   C5   E5   G5   C6   E6
//
//  Voice index == key index, so voice i plays the note that belongs to TPi.
//
//  Octave and timbre come from the on-board 5-way DIP switch SW3 instead of
//  from touch keys (all eight pads are needed as keys now).  A DIP switch is
//  a static level, so it needs no debouncing -- just two sync flops and a
//  latch at the audio sample rate.
//
//      ctrl[1:0] -> octave  0..3   (phase increment shifted left 0/1/2)
//      ctrl[3:2] -> timbre  0..3   (organ / square / saw / triangle)
//      ctrl5[0]  -> +1 volume step (SW3 position 5)
//
//  NOTE: octave 3 would need inc * 8, and the largest table entry already
//  needs *4 for the 4th harmonic; inc_lut is only safe up to *4 overall, so
//  the octave shift is clamped to 0..2 here as well.
//
//  PAD LAYOUT  (this is what actually cured the "two notes tremble" report)
//  ------------------------------------------------------------------------
//  The layout used to be the C major scale C4 D4 E4 F4 G4 A4 B4 C5, and the
//  two pads a player presses first -- TP0 and TP1 -- were therefore C4 and
//  D4, a whole tone apart.  Two equal-amplitude sines a whole tone apart sum
//  to an amplitude-modulated signal: the envelope falls to zero at
//  |f1-f2| = 32 Hz, i.e. about 30 complete fade-outs per second.  That is a
//  100 %-deep 30 Hz tremolo, and it is exactly what was being reported.
//
//  It is not a defect in the FPGA.  A spectrum measurement of the DAC stream
//  with two notes latched shows only two clean lines (263.95 Hz and 293.27 Hz,
//  every other bin below -34 dB) plus a 29.7 Hz envelope ripple; nothing else
//  is in the signal.  Any correct synthesiser playing those two pitches
//  sounds like that.
//
//  So the fix is musical, not digital: make every pair of neighbouring pads a
//  consonant interval.  NOTE_TAB is now an ascending C major arpeggio, so
//  adjacent pads are a major third, a minor third or a perfect fourth -- the
//  beat rates become 62..131 Hz, far above the ~30 Hz region the ear reads as
//  flutter/roughness.  Stacking several pads still gives a clean C major
//  chord, so the polyphony demo gets better, not worse.
//
//  Reverting to the one-octave scale is a one-line change to NOTE_TAB:
//      { 5'd12, 5'd11, 5'd9, 5'd7, 5'd5, 5'd4, 5'd2, 5'd0 }   // C4..C5
//
//  VOLUME-UP BUTTON
//    Silicon Key_3 (D7) is a VOLUME-UP button.  Each press steps the gain
//    index by one through 2..10 (0 dB .. +24 dB) and wraps back to 2, so the
//    instrument is always audible and a wrong number of presses can never
//    leave it silent.
//
//    It used to be the MUTE button, and that is what made the board dead
//    silent: every "Silicone Key_n" net on the Dock has a 10 k pull-up to
//    +1V5 and is only pulled to GND while the button is pressed, so the pin
//    idles HIGH -- mute was asserted at power-up and the DAC received zeros.
//    Any board key wired straight to a level-sensitive control has this
//    polarity trap; the fix is to make the control a one-shot EDGE (a press),
//    not a level.  The debounce below requires the pressed level to hold for
//    VDB samples (256 samples at 48.2 kHz ~ 5.3 ms), which both removes
//    contact bounce and makes the polarity unambiguous.
//
//    SW3 position 5 still adds one extra volume step on top (+1 index).
//
//  EXTRA STATIC SWITCHES
//    test  -> test tone (off-board switch / wire to 3V3)
//  Pure pass-through so that every audio control reaches audio_out.v through
//  one already-synchronised path.
//=============================================================================
`timescale 1ns / 1ps

module keymap8 #(
    // pressed level must be stable for VDB audio samples before it is accepted
    parameter integer VDB = 256,
    // hold this many audio samples to count as a LONG press (wavetable toggle)
    // 38 000 samples at 48.214 kHz ~ 0.79 s
    parameter integer VHOLD = 38_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,              // one clk pulse per audio sample
    input  wire [15:0] key_raw,         // 1 = pressed
    input  wire [3:0]  ctrl,            // {timbre[1:0], octave[1:0]} from DIP
    input  wire [1:0]  ctrl5,           // {<unused>, vol_lsb}  SW3-pos5
    input  wire        vup,             // Silicon Key_3: volume up, pressed = 0
    input  wire        test,            // test tone request
    output wire [7:0]  gate,            // 1 = sounding note key
    output wire [5*8-1:0] note_flat,    // 8 x 5 bit note index
    output reg  [1:0]  oct,
    output reg  [1:0]  timbre,
    output wire [3:0]  vol_raw,         // 4 bit volume index into audio_out
    output reg         test_o,
    output reg         wave_tog         // 1 clk pulse after a LONG Key_3 press
);

    // note index per key, packed as {key7, key6, ... key0}
    //   ascending C major arpeggio over two octaves (see PAD LAYOUT above)
    //   C4=0 E4=4 G4=7 C5=12 E5=16 G5=19 C6=24 E6=28   (see inc_lut.v)
    //
    //   Every neighbouring pair is a major third (4), a minor third (3) or a
    //   perfect fourth (5) semitones, so no two adjacent pads beat at the
    //   ~30 Hz that the ear hears as tremble.  The old C major scale layout
    //   { 12, 11, 9, 7, 5, 4, 2, 0 } is a one-line swap if melody is wanted.
    localparam [5*8-1:0] NOTE_TAB =
        { 5'd28, 5'd24, 5'd19, 5'd16,
          5'd12, 5'd7,  5'd4,  5'd0 };

    assign gate      = key_raw[7:0];
    assign note_flat = NOTE_TAB;

    //------------------------------------------------------------------
    // two-flop synchroniser for the static DIP levels
    //------------------------------------------------------------------
    reg [3:0] c_s0, c_s1;
    reg [1:0] c5_s0, c5_s1, c5_s2;
    reg       t_s0, t_s1, t_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_s0  <= 4'd0;
            c_s1  <= 4'd0;
            c5_s0 <= 2'd0;
            c5_s1 <= 2'd0;
            c5_s2 <= 2'd0;
            t_s0  <= 1'b0;
            t_s1  <= 1'b0;
            t_s2  <= 1'b0;
        end else begin
            c_s0  <= ctrl;
            c_s1  <= c_s0;
            c5_s0 <= ctrl5;
            c5_s1 <= c5_s0;
            c5_s2 <= c5_s1;
            t_s0  <= test;
            t_s1  <= t_s0;
            t_s2  <= t_s1;
        end
    end

    //------------------------------------------------------------------
    // volume-up button: sync, debounce, one-shot press
    //
    // The board pulls the net UP and the switch shorts it to GND, so an
    // un-pressed key reads 1 and a press reads 0.
    //------------------------------------------------------------------
    reg        v_s0, v_s1;
    reg        v_stable, v_stable_d;
    reg [7:0]  v_cnt;
    wire       v_press = v_stable_d && !v_stable;   // 1 clk pulse on press

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s0       <= 1'b1;    // power-up state of an un-pressed key
            v_s1       <= 1'b1;
            v_stable   <= 1'b1;
            v_stable_d <= 1'b1;
            v_cnt      <= 8'd0;
        end else begin
            v_s0 <= vup;
            v_s1 <= v_s0;
            if (v_s1 == v_stable) begin
                v_cnt <= 8'd0;
            end else if (v_cnt == (VDB[7:0] - 8'd1)) begin
                v_stable <= v_s1;      // new level accepted
                v_cnt    <= 8'd0;
            end else begin
                v_cnt <= v_cnt + 8'd1;
            end
            v_stable_d <= v_stable;
        end
    end

    //------------------------------------------------------------------
    // volume index, 2..10, wraps back to 2 after 10
    //
    //  It used to be 6..10, i.e. 4.0x..16x with no way down.  That is fine for
    //  one note (8188 counts) but with latch mode the player stacks voices and
    //  the sum ran into the limiter from five notes upwards (see the head room
    //  table in docs/音量与削波记录.md).  Index 2 is 1.0x, where all eight
    //  voices still fit without touching the knee.
    //------------------------------------------------------------------
    reg [3:0] vol_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vol_idx <= 4'd6;           // +12 dB, see audio_out.v
        else if (v_press)
            vol_idx <= (vol_idx >= 4'd10) ? 4'd2 : (vol_idx + 4'd1);
    end

    // SW3 position 5 adds one more step; clamp at the top of the table
    wire [4:0] vol_sum = {1'b0, vol_idx} + {4'b0, c5_s2[0]};
    assign vol_raw = (vol_sum > 5'd10) ? 4'd10 : vol_sum[3:0];

    //------------------------------------------------------------------
    // LONG press on the same button toggles the 4-wavetable additive mode
    //
    //  Key_3 is a two-function button:
    //      short press  -> volume +1   (unchanged: it fires on press, above)
    //      held >= VHOLD-> one wave_tog pulse when the threshold is crossed
    //  Counting happens on `en` (the audio sample rate) so the hold time is
    //  independent of the system clock.  Note that a long press still steps
    //  the volume by one on its leading edge -- harmless by design (the
    //  volume index always stays inside the audible 6..10 window).
    //------------------------------------------------------------------
    reg [15:0] hcnt;
    reg        hold_fired, hold_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt       <= 16'd0;
            hold_fired <= 1'b0;
            hold_prev  <= 1'b0;
            wave_tog   <= 1'b0;
        end else begin
            hold_prev <= hold_fired;
            wave_tog  <= hold_fired && !hold_prev;   // one clk pulse
            if (en) begin
                if (!v_stable) begin                  // debounced "pressed"
                    if (hcnt == VHOLD[15:0] - 16'd1) begin
                        hcnt       <= VHOLD[15:0];
                        hold_fired <= 1'b1;
                    end else if (hcnt < VHOLD[15:0]) begin
                        hcnt <= hcnt + 16'd1;
                    end
                end else begin                        // released -> re-arm
                    hcnt       <= 16'd0;
                    hold_fired <= 1'b0;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // static controls latched at the audio sample rate
    //------------------------------------------------------------------
    wire [1:0] oct_raw = (c_s1[1:0] > 2'd2) ? 2'd2 : c_s1[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oct    <= 2'd0;
            timbre <= 2'd0;
            test_o <= 1'b0;
        end else if (en) begin
            oct    <= oct_raw;
            timbre <= c_s1[3:2];
            test_o <= t_s2;
        end
    end

endmodule
