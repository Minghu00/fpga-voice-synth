//=============================================================================
// test_mode.v  --  competition on-site self test ("测试模式")
//
//  WHY
//  ---
//  The marking scheme asks for a mode that, on the spot, plays several
//  *different* frequencies at once so that a spectrum analyser shows the
//  corresponding number of independent peaks -- proof that the tones are
//  generated live and not read out of a pre-recorded PCM buffer.
//
//  WHAT IT DOES
//  ------------
//  When test mode is latched on it takes over four signals that normally
//  come from the player:
//
//      gate   -> 8'hFF          all eight voices keyed
//      note   -> NOTE_SET       8 fixed, well spread pitches
//      timbre -> organ          so each voice is ONE pure sine
//      octave -> 0              deterministic, and keeps inc_lut in range
//      volume -> VOL_TEST       headroom for eight sines summed together
//
//  Why timbre = organ: amp_tab selects {0,0,0,32767} for organ, i.e. only
//  component 0 is audible and the voice is a clean sine.  If all four
//  additive components were left on, every voice would also emit its 2nd /
//  3rd / 4th harmonics; those are integer multiples of the fundamental, so
//  peaks from different voices land on top of each other and the analyser
//  would show fewer peaks than oscillators.  One component per voice keeps
//  eight clean, countable peaks.
//
//  HOW IT IS ENTERED
//  -----------------
//  Hold Silicon Key_3 (the volume-up key, P1 pin, active LOW) while the
//  board comes out of reset.  A short window (INIT_WIN clocks) after reset
//  release is monitored; if the key is seen pressed anywhere in that window
//  the mode latches and stays latched until the next power cycle.  Nothing
//  is written to any pin, so the trick costs no extra I/O and the key still
//  works normally when the board is simply switched on.
//
//  The window exists because reset comes from a push button too: the player
//  presses reset and Key_3 together, releases reset, then releases Key_3.
//=============================================================================
`timescale 1ns / 1ps

module test_mode #(
    parameter integer        VOICES   = 8,
    parameter integer        INIT_WIN = 108_000,   // 1 ms at 108 MHz
    parameter [3:0]          VOL_TEST = 4'd2,      // 1.0x gain, see audio_out.v
    // voice 7 ... voice 0, three semitones apart over two octaves:
    //   C4 261.6  D#4 311.1  F#4 370.0  G#4 415.3
    //   C5 523.3  D#5 622.3  F#5 740.0  G#5 830.6
    // smallest gap between neighbours is 45 Hz, comfortably resolvable.
    parameter [5*VOICES-1:0] NOTE_SET = {5'd21, 5'd18, 5'd15, 5'd12,
                                         5'd9,  5'd6,  5'd3,  5'd0}
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                vup_n,      // raw pin, active LOW (pressed = 0)

    input  wire [VOICES-1:0]   gate_in,
    input  wire [5*VOICES-1:0] note_in,
    input  wire [1:0]          timbre_in,
    input  wire [1:0]          oct_in,
    input  wire [3:0]          vol_in,

    output reg                 test_en,    // latched; 1 = test mode active
    output reg  [VOICES-1:0]   gate_out,
    output reg  [5*VOICES-1:0] note_out,
    output reg  [1:0]          timbre_out,
    output reg  [1:0]          oct_out,
    output reg  [3:0]          vol_out
);

    //------------------------------------------------------------------
    // synchronise the raw key and turn it into an active-high "pressed"
    //------------------------------------------------------------------
    reg [1:0] vsync;
    wire      pressed = ~vsync[1];

    always @(posedge clk) begin
        if (!rst_n) vsync <= 2'b11;            // released (pin pulled up)
        else        vsync <= {vsync[0], vup_n};
    end

    //------------------------------------------------------------------
    // power-up window: latch test mode if the key was down at any time
    // between reset release and the end of INIT_WIN
    //------------------------------------------------------------------
    reg        armed;                          // 1 while the window is open
    reg [19:0] wcnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            armed   <= 1'b1;
            wcnt    <= 20'd0;
            test_en <= 1'b0;
        end else begin
            if (armed && pressed)
                test_en <= 1'b1;               // sticky

            if (armed) begin
                if (wcnt >= INIT_WIN[19:0]) begin
                    armed <= 1'b0;             // window closed for ever
                end else begin
                    wcnt <= wcnt + 20'd1;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // override muxes
    //
    // The outputs are REGISTERED on purpose.  Handing the mux result
    // straight to osc_bank put one extra LUT level in front of the
    // note -> inc_lut -> << octave pre-compute path, which is the tightest
    // path in the design; measured Fmax dropped from 119.2 MHz to
    // 108.9 MHz, i.e. essentially no margin over the 108 MHz constraint.
    // Registering the mux here costs ~56 flops and puts the shifter back
    // behind a plain flop-to-flop path.  The one-clock (9 ns) latency on a
    // note / octave / timbre change is irrelevant: those settings change at
    // human speed.
    //------------------------------------------------------------------
    wire [VOICES-1:0]   gate_nx   = test_en ? {VOICES{1'b1}} : gate_in;
    wire [5*VOICES-1:0] note_nx   = test_en ? NOTE_SET       : note_in;
    wire [1:0]          timbre_nx = test_en ? 2'd0           : timbre_in;
    wire [1:0]          oct_nx    = test_en ? 2'd0           : oct_in;
    wire [3:0]          vol_nx    = test_en ? VOL_TEST       : vol_in;

    always @(posedge clk) begin
        if (!rst_n) begin
            gate_out   <= {VOICES{1'b0}};
            note_out   <= {5*VOICES{1'b0}};
            timbre_out <= 2'd0;
            oct_out    <= 2'd0;
            vol_out    <= 4'd0;
        end else begin
            gate_out   <= gate_nx;
            note_out   <= note_nx;
            timbre_out <= timbre_nx;
            oct_out    <= oct_nx;
            vol_out    <= vol_nx;
        end
    end

endmodule
