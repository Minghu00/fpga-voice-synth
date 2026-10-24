//=============================================================================
// top_inst.v  --  8-key touch instrument, FPGA synthesiser engine
//                  Tang Primer 20K (GW2A-18C) + Dock 3709/3714
//
//  Signal chain
//      TTP229 8-key pad --2-wire--> keymap8 --> 8 voices x 4 additive
//        harmonics --> 8 x ADSR --> mixer16 --> I2S --> MAX98357
//      and the same mixed sample + envelope history --> 480x272 RGB panel
//
//  Polyphony
//      The touch chip reports the pads as a 16-bit bitmap, so any number of
//      pads can be down at once; each of the 8 voices has its own phase
//      accumulators, its own envelope generator and its own mixer tap, so
//      eight keys sound simultaneously.  (The chip itself must be strapped
//      for multi-key: TP3=0, TP4=0 means "all multi-keys".)
//
//  Octave / timbre come from the on-board 5-way DIP switch SW3 rather than
//  from touch pads, because all eight pads are needed as piano keys.
//
//  Clocking
//      clk27 (H11) --rPLL x4 /1, VCO=864 MHz--> clk_sys = 108 MHz
//      2240 clk per audio frame          ->  fs   = 48 214.2857 Hz
//      108 MHz / 12                      ->  pixel clock  = 9 MHz
//      I2S 16 bit/slot, BCLK_HALF = 35   ->  BCLK = 1.5429 MHz
//
//  Pins -- see constraints/inst.cst
//      clk27     H11                       rst_n     T3  (Silicon Key_1)
//      tp_scl    P8   (J14-8  MIC_DAT0)    tp_sdo    T8  (J14-7  MIC_DAT1)
//      i2s_bclk  R8   (J14-9  MIC_DAT2)    i2s_lrclk T7  (J14-10 MIC_DAT3)
//      i2s_din   T6   (J14-11 MIC_BCK)     test_sw   P6  (J14-12 MIC_WS)
//                                       ^^ P6/T6 are pin-swapped on J14:
//                                          pin 11 = T6, pin 12 = P6.
//      dip[3:0]  E9 E8 T4 T5  (SW3 positions 1..4, 1.5 V bank)
//      lcd_*     J7 40-pin FPC, see LCD接口映射.md
//=============================================================================
`timescale 1ns / 1ps

module top_inst #(
    // TTP229 timing (production values; the testbench overrides them)
    parameter integer INIT_CLK   = 21_600_000,
    parameter integer POLL_CLK   = 108_000,
    parameter integer SCL_HALF   = 108,
    parameter integer ACTIVE_LOW = 1,
    // envelope rates (production values; the testbench overrides them)
    parameter integer ATT_STEP = 340,
    parameter integer DEC_STEP = 2,
    parameter integer REL_STEP = 6,
    parameter integer SUSTAIN  = 39_321,
    // sys clocks per LCD pixel.  12 -> 9 MHz for the real panel; the
    // testbench lowers it so 272-line frames simulate quickly.
    parameter integer DIV      = 12
) (
    input  wire clk27,
    input  wire rst_n,
    input  wire tp_sdo,
    input  wire [3:0] dip,          // SW3 positions 1..4: octave / timbre
    input  wire       sw5_vol,      // SW3 position 5 : +1 volume step
    input  wire       vup_sw,       // Silicon Key_3 : volume up (pressed = 0)
    input  wire       test_sw,      // test tone      : 188 Hz square wave
    input  wire key_btn,            // Silicon Key_2 (T2): latch on/off
    output wire tp_scl,
    output wire i2s_bclk,
    output wire i2s_lrclk,
    output wire i2s_din,
    // 480x272 RGB panel (J7 FPC)
    output wire lcd_dclk,
    output wire lcd_hs,
    output wire lcd_vs,
    output wire lcd_de,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [4:0] lcd_b
);

    localparam integer VOICES = 8;

    //------------------------------------------------------------------
    // clocking and reset
    //------------------------------------------------------------------
    wire clk_sys;
    wire locked;

    pll_sys u_pll (
        .clk27  (clk27),
        .rst_n  (rst_n),
        .clk_sys(clk_sys),
        .locked (locked)
    );

    wire arst_n = rst_n & locked;

    reg [1:0] rsync;
    always @(posedge clk_sys or negedge arst_n) begin
        if (!arst_n)
            rsync <= 2'b00;
        else
            rsync <= {rsync[0], 1'b1};
    end
    wire srst_n = rsync[1];

    //------------------------------------------------------------------
    // audio frame timebase
    //------------------------------------------------------------------
    wire [11:0] fc;
    wire        sample_tick;
    wire        osc_ph, env_ph, mix_ph;

    frame_gen u_frame (
        .clk        (clk_sys),
        .rst_n      (srst_n),
        .fc         (fc),
        .sample_tick(sample_tick),
        .osc_ph     (osc_ph),
        .env_ph     (env_ph),
        .mix_ph     (mix_ph)
    );

    //------------------------------------------------------------------
    // touch keyboard
    //------------------------------------------------------------------
    wire [15:0] key_raw;
    wire [15:0] key_hi;
    wire [15:0] poll_cnt;
    wire        frame_ok;
    wire        awake;

    ttp229_rx #(
        .INIT_CLK  (INIT_CLK),
        .POLL_CLK  (POLL_CLK),
        .SCL_HALF  (SCL_HALF),
        .ACTIVE_LOW(ACTIVE_LOW)
    ) u_ttp (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .tp_sdo   (tp_sdo),
        .tp_scl   (tp_scl),
        .key_raw  (key_raw),
        .key_hi   (key_hi),
        .poll_cnt (poll_cnt),
        .frame_ok (frame_ok),
        .awake    (awake)
    );

    wire [7:0]  gate_live;
    wire [39:0] note_flat;
    wire [1:0]  oct;
    wire [1:0]  timbre;
    wire [3:0]  vol_raw;
    wire        test_s;

    keymap8 u_keymap (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .en       (sample_tick),
        .key_raw  (key_raw),
        .ctrl     (dip),
        .ctrl5    ({1'b0, sw5_vol}),
        .vup      (vup_sw),
        .test     (test_sw),
        .gate     (gate_live),
        .note_flat(note_flat),
        .oct      (oct),
        .timbre   (timbre),
        .vol_raw  (vol_raw),
        .test_o   (test_s)
    );

    //------------------------------------------------------------------
    // Latch (hold) mode, toggled by Silicon Key_2.
    //
    // The TTP229 chip defaults to TP3=TP4=1, i.e. "all single-key": it only
    // ever reports ONE pad, so two fingers cannot light two cells no matter
    // what the FPGA does.  (To get true multi-touch the chip's TP3 and TP4
    // pads have to be tied to VSS.)
    //
    // Latch mode works around that in the FPGA: each tap toggles its note
    // on/off, so a chord can be built up one finger at a time:
    //     tap C4, tap E4, tap G4  ->  C major triad sounding together.
    // Press Key_2 again to go back to normal touch-and-hold play.
    //------------------------------------------------------------------
    reg [7:0] latch;                 // latched gate bitmap
    reg [7:0] key_d;                 // previous touch bitmap
    reg       latch_mode;

    reg [2:0] btn_sync;              // 2FF + 1 edge-detect stage
    wire      btn_rise = btn_sync[2] & ~btn_sync[1];
    wire [7:0] key_rise = gate_live & ~key_d;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            btn_sync   <= 3'b000;
            latch_mode <= 1'b0;
            latch      <= 8'd0;
            key_d      <= 8'd0;
        end else begin
            btn_sync <= {btn_sync[1:0], key_btn};
            if (btn_rise)
                latch_mode <= ~latch_mode;

            if (sample_tick) begin
                key_d <= gate_live;
                if (!latch_mode)
                    latch <= 8'd0;                 // leaving latch clears it
                else if (key_rise != 8'd0)
                    latch <= latch ^ key_rise;     // tap = toggle that note
            end
        end
    end

    wire [7:0] gate = latch_mode ? latch : gate_live;

    //------------------------------------------------------------------
    // 32 oscillators (8 voices x 4 additive harmonics)
    //------------------------------------------------------------------
    wire [16*VOICES-1:0] raw_flat;

    osc_bank #(
        .VOICES (VOICES),
        .NCOMP  (4)
    ) u_osc (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .fc       (fc),
        .note_flat(note_flat),
        .timbre   (timbre),
        .oct      (oct),
        .raw_flat (raw_flat)
    );

    //------------------------------------------------------------------
    // one ADSR per voice
    //------------------------------------------------------------------
    wire [16*VOICES-1:0] env_flat;

    genvar gi;
    generate
        for (gi = 0; gi < VOICES; gi = gi + 1) begin : g_env
            adsr #(
                .ATT_STEP (ATT_STEP[15:0]),
                .DEC_STEP (DEC_STEP[15:0]),
                .REL_STEP (REL_STEP[15:0]),
                .SUSTAIN  (SUSTAIN[15:0])
            ) u_adsr (
                .clk   (clk_sys),
                .rst_n (srst_n),
                .en    (sample_tick),
                .gate  (gate[gi]),
                .env   (env_flat[gi*16 +: 16]),
                .active()
            );
        end
    endgenerate

    //------------------------------------------------------------------
    // mixdown -- MIX_SHIFT 3 so that 8 voices at full scale reach exactly
    // full scale without clipping (8 x 32767 >> 3 = 32767)
    //------------------------------------------------------------------
    wire [15:0] mix_out;
    wire        mix_ok;              // one clk pulse per frame, mix_out valid

    mixer16 #(
        .VOICES   (VOICES),
        .MIX_SHIFT(3)
    ) u_mixer (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .fc       (fc),
        .mix_ph   (mix_ph),
        .raw_flat (raw_flat),
        .env_flat (env_flat),
        .out      (mix_out),
        .out_ok   (mix_ok)
    );

    //------------------------------------------------------------------
    // final audio stage: digital volume + test tone + mute
    //
    // The mixer hands over one sample per frame, but i2s_tx restarts its
    // bit stream at fc==0, which is a different instant.  audio_out.v
    // therefore registers the final sample and pulses sample_tick, and
    // i2s_tx reloads {L,R} on that same clk.  Without this the I2S word
    // latched whatever was on the mix node at the frame boundary -- after
    // reset that was zero, which is exactly the "silent but the display
    // shows a perfect waveform" symptom.
    //------------------------------------------------------------------
    wire signed [15:0] audio_s;
    wire               audio_tick;

    audio_out #(
        .TONE_DIV (256)
    ) u_aout (
        .clk       (clk_sys),
        .rst_n     (srst_n),
        .frame_tick(sample_tick),
        .mix_ok    (mix_ok),
        .mix_in    (mix_out),
        .vol_raw   (vol_raw),
        // Mute is NOT driven by a board key any more.  Every "Silicone Key_n"
        // net on the Dock has a 10 k pull-up to +1V5 and only goes low while
        // the button is pressed, so a level-sensitive mute idled HIGH and
        // silenced the DAC at power-up.  Key_3 is a volume-up button now.
        .mute      (1'b0),
        .test_tone (test_s),
        .sample    (audio_s),
        .sample_tick(audio_tick)
    );

    //------------------------------------------------------------------
    // I2S out (mono engine duplicated to L/R)
    //------------------------------------------------------------------
    i2s_tx #(
        .BCLK_HALF (35)
    ) u_i2s (
        .clk       (clk_sys),
        .rst_n     (srst_n),
        .fc        (fc),
        .load_tick (audio_tick),
        .sample_l  (audio_s),
        .sample_r  (audio_s),
        .bclk      (i2s_bclk),
        .lrclk     (i2s_lrclk),
        .din       (i2s_din)
    );

    //------------------------------------------------------------------
    // display history writers
    //   waveform : one entry per audio sample       ( 9.96 ms window)
    //   envelope : one entry per 32nd audio sample  (318 ms window)
    //------------------------------------------------------------------
    reg [8:0] wptr_w;
    reg [8:0] wptr_e;
    reg [4:0] ecnt;
    wire      env_wr = sample_tick && (ecnt == 5'd31);

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            wptr_w <= 9'd0;
            wptr_e <= 9'd0;
            ecnt   <= 5'd0;
        end else begin
            if (scope_tick) begin          // one step per displayed sample
                wptr_w <= wptr_w + 9'd1;
                ecnt   <= ecnt + 5'd1;
            end
            if (env_wr)
                wptr_e <= wptr_e + 9'd1;
        end
    end

    //------------------------------------------------------------------
    // loudest voice drives the envelope trace.
    //
    // The max of 8 16-bit envelopes is far too deep to do in one 108 MHz
    // cycle: implemented as a single combinational reduction it produced a
    // 32-level path (env -> max tree -> history RAM) and Fmax collapsed to
    // 34 MHz.  It is therefore pipelined into three registered stages:
    //     stage 1 : 4 pairwise maxima
    //     stage 2 : 2 pairwise maxima
    //     stage 3 : the final maximum
    // All three advance on sample_tick, so the traced value trails the live
    // envelopes by 3 samples (~62 us) -- invisible on a 318 ms trace.
    //
    // NOTE: the tree assumes VOICES == 8.
    //------------------------------------------------------------------
    function [15:0] max2;
        input [15:0] a;
        input [15:0] b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    reg [15:0] mx_a, mx_b, mx_c, mx_d;
    reg [15:0] mx_ab, mx_cd;
    reg [15:0] env_max;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            mx_a   <= 16'd0;
            mx_b   <= 16'd0;
            mx_c   <= 16'd0;
            mx_d   <= 16'd0;
            mx_ab  <= 16'd0;
            mx_cd  <= 16'd0;
            env_max <= 16'd0;
        end else if (sample_tick) begin
            mx_a  <= max2(env_flat[ 0*16 +: 16], env_flat[ 1*16 +: 16]);
            mx_b  <= max2(env_flat[ 2*16 +: 16], env_flat[ 3*16 +: 16]);
            mx_c  <= max2(env_flat[ 4*16 +: 16], env_flat[ 5*16 +: 16]);
            mx_d  <= max2(env_flat[ 6*16 +: 16], env_flat[ 7*16 +: 16]);
            mx_ab <= max2(mx_a, mx_b);
            mx_cd <= max2(mx_c, mx_d);
            env_max <= max2(mx_ab, mx_cd);
        end
    end

    //------------------------------------------------------------------
    // waveform trigger
    //
    // Without a trigger the scope shows the newest 480 samples, so a steady
    // tone scrolls across the screen (that is what a free-running scope
    // does).  Instead we remember where the newest rising zero crossing is
    // and start the display window there; a steady tone then stands still.
    // If no crossing has been seen for ~2 windows (silence, or a signal with
    // a large DC offset) we fall back to the free-running window.
    //
    // The trace follows the FINAL audio sample (post volume / mute / test
    // tone), so what is drawn is literally what leaves the I2S pin.
    //------------------------------------------------------------------
    // The trace follows the mixer output rather than the final I2S word.
    // audio_s has already been through >>SHIFT_HP (8x) and the Q8 volume
    // (64/256 at power-on), i.e. 32x smaller, so one voice peaked at +-64
    // and the trace collapsed into a 4-row smear.  Drawing mix_out keeps a
    // single voice at ~94 % of the box; the audio path itself is unchanged.
    wire signed [15:0] scope_s   = mix_out;
    wire               scope_tick = mix_ok;

    reg signed [15:0] mix_prev;

    //----------------------------------------------------------------------
    // Rising zero-crossing trigger
    //
    // The display window STARTS on a rising zero crossing, so a steady tone
    // always begins at the same phase and the picture stands still.
    //
    // Start-triggering needs a crossing that is at least SPAN (=480) samples
    // old, otherwise the right-hand columns would read samples that have not
    // been written yet.  The history buffer is only 512 deep, so an address
    // comparison `wptr - cz >= 480` WRAPS and silently rejects every crossing
    // older than 511 samples -- for a 184-sample note that leaves a 32-sample
    // window of opportunity, so 83 % of frames fell back to the free-running
    // window and the trace jumped to a random phase.  Ages are therefore kept
    // as counters, never as address differences, and the oldest crossing that
    // is at least SPAN behind the pointer is used.  Any crossing gives the
    // same picture, so switching between slots is invisible.
    //----------------------------------------------------------------------
    localparam integer SPAN = 480;

    reg [8:0]  cz [0:3];             // crossing addresses, newest in cz[0]
    reg [10:0] cz_age [0:2];         // age in samples; slot 3 is always >= 480

    reg [8:0] tsel;
    reg       tok;
    integer   ci;
    wire      xing = (scope_s > 16'sd0) && (mix_prev <= 16'sd0);
    always @(*) begin
        tsel = cz[3];
        tok  = 1'b1;
        for (ci = 2; ci >= 0; ci = ci - 1) begin
            if ((cz_age[ci] >= SPAN[10:0]) && (cz_age[ci] < 11'd960)) begin
                tsel = cz[ci];
                tok  = 1'b1;
            end
        end
    end

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            mix_prev <= 16'sd0;
            cz[0] <= 9'd0; cz[1] <= 9'd0; cz[2] <= 9'd0; cz[3] <= 9'd0;
            cz_age[0] <= 11'd200; cz_age[1] <= 11'd400; cz_age[2] <= 11'd600;
        end else if (scope_tick) begin
            mix_prev <= scope_s;
            if (xing) begin
                // scope_tick is also the write enable and wptr_w the address the
                // sample lands on, so wptr_w names this newest stored sample.
                cz[3] <= cz[2]; cz[2] <= cz[1]; cz[1] <= cz[0];
                cz[0] <= wptr_w;
                cz_age[2] <= (cz_age[1] > 11'd600) ? 11'd600 : cz_age[1];
                cz_age[1] <= (cz_age[0] > 11'd600) ? 11'd600 : cz_age[0];
                cz_age[0] <= 11'd0;
            end else begin
                // saturate instead of wrapping: a wrapped age would look young
                // again and hand the window an address that is not a crossing
                if (cz_age[0] < 11'd600) cz_age[0] <= cz_age[0] + 11'd1;
                if (cz_age[1] < 11'd600) cz_age[1] <= cz_age[1] + 11'd1;
                if (cz_age[2] < 11'd600) cz_age[2] <= cz_age[2] + 11'd1;
            end
        end
    end

    //------------------------------------------------------------------
    // panel
    //------------------------------------------------------------------
    lcd_scope #(
        .VOICES (VOICES),
        .DIV    (DIV)
    ) u_lcd (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .wr_en_w  (scope_tick),
        .wr_addr_w(wptr_w),
        .wr_data_w(scope_s),
        .trig_addr(tsel),
        .trig_ok  (tok),
        .wr_en_e  (env_wr),
        .wr_addr_e(wptr_e),
        .wr_data_e(env_max),
        .latch_mode_w(latch_mode),
        .key_gate (gate),
        .env_flat (env_flat),
        .oct      (oct),
        .timbre   (timbre),
        .vol      (vol_raw),
        .lcd_dclk (lcd_dclk),
        .lcd_hs   (lcd_hs),
        .lcd_vs   (lcd_vs),
        .lcd_de   (lcd_de),
        .lcd_r    (lcd_r),
        .lcd_g    (lcd_g),
        .lcd_b    (lcd_b)
    );

endmodule
