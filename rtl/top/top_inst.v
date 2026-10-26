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
    parameter integer DIV      = 12,
    // audio samples a Key_3 press must be held to toggle wavetable mode
    // (production 38 000 samples ~ 0.79 s; the testbench lowers it)
    parameter integer WHOLD    = 38_000,
    // sys clocks a Key_2 press must be held to step the FX bank
    // (production 86 400 000 clocks ~ 0.80 s; the testbench lowers it)
    parameter integer BTHR     = 86_400_000
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
    wire        wave_tog;

    keymap8 #(
        .VHOLD (WHOLD)
    ) u_keymap (
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
        .test_o   (test_s),
        .wave_tog (wave_tog)
    );

    //------------------------------------------------------------------
    // on-site self test ("测试模式")
    //
    // Holds every voice on, with eight fixed and well spread pitches, a pure
    // sine timbre and a fixed gain, so a spectrum analyser can count the live
    // oscillators one by one.  Entered by holding Key_3 while the board comes
    // out of reset; see test_mode.v for the full rationale.
    //------------------------------------------------------------------
    wire [7:0]  gate_t;
    wire [39:0] note_t;
    wire [1:0]  oct_t;
    wire [1:0]  timbre_t;
    wire [3:0]  vol_t;
    wire        test_en;

    test_mode #(
        .VOICES (VOICES)
    ) u_test (
        .clk       (clk_sys),
        .rst_n     (srst_n),
        .vup_n     (vup_sw),
        .gate_in   (gate_live),
        .note_in   (note_flat),
        .timbre_in (timbre),
        .oct_in    (oct),
        .vol_in    (vol_raw),
        .test_en   (test_en),
        .gate_out  (gate_t),
        .note_out  (note_t),
        .timbre_out(timbre_t),
        .oct_out   (oct_t),
        .vol_out   (vol_t)
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
    wire      btn_rise = btn_sync[2] & ~btn_sync[1];   // press  (1 -> 0)
    wire      btn_rel  = ~btn_sync[2] & btn_sync[1];   // release(0 -> 1)
    wire [7:0] key_rise = gate_live & ~key_d;

    //------------------------------------------------------------------
    // Key_2 long press (~0.8 s) cycles the expression / effect bank.
    //
    //  fx_mode is a PRESET index, not a bit mask.  A bit mask would need one
    //  bit per effect and the bank would be 32 steps long, which is unusable
    //  at the bench; an index keeps it at 8 and still reaches every effect
    //  on its own and the useful combinations.
    //
    //      fx_mode   vibrato   glide   echo   reverb   chorus
    //      0  off        -       -       -       -        -     <- default
    //      1  vibrato    on      -       -       -        -
    //      2  glide      -       on      -       -        -
    //      3  echo       -       -       on      -        -
    //      4  reverb     -       -       -       on       -
    //      5  chorus     -       -       -       -        on
    //      6  echo+reverb-       -       on      on       -
    //      7  everything on      on      on      on       on
    //
    // A SHORT press still toggles latch mode, exactly as before; a long press
    // sets btn_long so the release edge does not also flip latch mode.
    //------------------------------------------------------------------
    localparam [26:0] BTHR_C  = BTHR[26:0];          // 0.8 s at 108 MHz
    //  A second, longer threshold on the same button cycles the DISPLAY mode.
    //  Key_2 already owns latch mode (short tap) and the effect bank (0.8 s),
    //  so the remaining gesture has to be "keep holding": at 1.6 s the effect
    //  bank has already stepped once and stops, and from there the display
    //  page advances once more.  No new pin, nothing to explain at the bench.
    localparam [26:0] VTHR_C = {BTHR_C[25:0], 1'b0}; // 2 x BTHR = 1.6 s

    reg [26:0] bhold;
    reg        btn_long;
    reg        btn_vlong;
    reg [2:0]  fx_mode;
    //  Display page: 0 = waveform, 1 = spectrum, 2 = Lissajous (X-Y).
    reg  [1:0] dmode;
    wire       btn_down      = ~btn_sync[1];
    wire       btn_down_prev = ~btn_sync[2];

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            btn_sync   <= 3'b111;
            latch_mode <= 1'b0;
            latch      <= 8'd0;
            key_d      <= 8'd0;
            bhold      <= 27'd0;
            btn_long   <= 1'b0;
            btn_vlong  <= 1'b0;
            fx_mode    <= 3'd0;
            dmode      <= 2'd0;
        end else begin
            btn_sync <= {btn_sync[1:0], key_btn};

            // a fresh press restarts the hold timer
            if (btn_down && !btn_down_prev) begin
                bhold     <= 27'd0;
                btn_long  <= 1'b0;
                btn_vlong <= 1'b0;
            end else if (btn_down) begin
                if (bhold < BTHR_C) begin
                    bhold <= bhold + 1'b1;
                end else if (bhold < VTHR_C) begin
                    bhold <= bhold + 1'b1;
                    if (!btn_long) begin
                        btn_long <= 1'b1;
                        fx_mode  <= fx_mode + 3'd1;
                    end
                end else if (!btn_vlong) begin
                    btn_vlong <= 1'b1;
                    dmode     <= (dmode == 2'd2) ? 2'd0 : (dmode + 2'd1);
                end
            end

            // Toggle latch mode on a SHORT press.  The decision is taken on
            // the release edge so that a LONG press is free to cycle the FX
            // bank and a VERY LONG press to change the display page, instead
            // of doing everything at once.
            if (btn_rel && !btn_long)
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

    // Test mode wins over latch mode: it wants every voice on regardless of
    // what the player latched before reset.  Wavetable mode does not touch the
    // gate at all -- it only changes which table each additive component
    // reads, so it is compatible with normal play, latch mode and test mode.
    wire [7:0] gate = test_en ? gate_t
                            : (latch_mode ? latch : gate_live);

    //------------------------------------------------------------------
    // Wavetable mode: 4 different tables, one per additive component
    //
    // Toggled by a LONG press (~0.79 s) of Key_3 -- the same button that steps
    // the volume on a short press.  No new pin, and the selection is sticky
    // across power cycles only in the sense that it resets to OFF, which is
    // what you want: the default sound is exactly the one from before.
    //------------------------------------------------------------------
    reg wave_mode;

    always @(posedge clk_sys) begin
        if (!srst_n)
            wave_mode <= 1'b0;
        else if (wave_tog)
            wave_mode <= ~wave_mode;
    end

    //------------------------------------------------------------------
    // Expression bank  (赛题拓展②: 滑音 / 颤音 / 延迟)
    //
    //   glide   : portamento on voice 0, re-purposed as a lead voice that
    //             follows the most recently touched pad.  Every other voice
    //             keeps playing its own key, so a chord plus a gliding lead
    //             is possible.
    //   glide   : voice 0 slews exponentially toward the newest key.
    //   vibrato : 5 Hz multiplicative LFO on every voice.
    //   echo    : one in-FPGA delay line after the mixer.
    //   reverb  : four taps off the same delay line, summed.
    //   chorus  : one LFO-modulated tap off the same delay line.
    //
    // fx_mode is a preset index -- see the table above the counter.  All of
    // them are OFF at fx_mode = 0, and with them off every signal takes
    // exactly the same value as before these features existed.
    //------------------------------------------------------------------
    wire vib_on   = (fx_mode == 3'd1) || (fx_mode == 3'd7);
    wire glide_en = (fx_mode == 3'd2) || (fx_mode == 3'd7);
    wire echo_on  = (fx_mode == 3'd3) || (fx_mode == 3'd6) || (fx_mode == 3'd7);
    wire rvb_on   = (fx_mode == 3'd4) || (fx_mode == 3'd6) || (fx_mode == 3'd7);
    wire cho_on   = (fx_mode == 3'd5) || (fx_mode == 3'd7);

    //------------------------------------------------------------------
    // vibrato LFO (one shared LFO, applied per voice inside osc_bank)
    //------------------------------------------------------------------
    reg  signed [5:0] vib_d;
    reg  signed [5:0] vib_abs;

    //------------------------------------------------------------------
    // The LFO is written INLINE, not as a sub-module.
    //
    //   GowinSynthesis reported "NL0002: the module vibrato_lfo
    //   instantiated to u_lfo is swept in optimizing" and the
    //   synthesised hierarchy confirmed that no u_lfo survived -- the
    //   vibrato was silently deleted from the bitstream even though both
    //   of its outputs are consumed.  Keeping the logic in this module
    //   removes the module boundary the optimiser was dissolving.
    //------------------------------------------------------------------
    localparam integer VIB_PH_INC = 1740;   // 5.0004 Hz at 48 214.2857 Hz
    localparam integer VIB_DEPTH  = 18;     // +-18/1024 = +-30 cent
                                            // the quarter-sine table below already peaks
                                            // at exactly DEPTH, so no clamp is needed

    // quarter sine, 32 entries, round(DEPTH * sin(pi/2 * i/32))
    function [5:0] vib_qsin;
        input [4:0] i;
        begin
            case (i)
                5'd0:  vib_qsin = 6'd0;   5'd1:  vib_qsin = 6'd1;
                5'd2:  vib_qsin = 6'd2;   5'd3:  vib_qsin = 6'd3;
                5'd4:  vib_qsin = 6'd4;   5'd5:  vib_qsin = 6'd4;
                5'd6:  vib_qsin = 6'd5;   5'd7:  vib_qsin = 6'd6;
                5'd8:  vib_qsin = 6'd7;   5'd9:  vib_qsin = 6'd8;
                5'd10: vib_qsin = 6'd8;   5'd11: vib_qsin = 6'd9;
                5'd12: vib_qsin = 6'd10;  5'd13: vib_qsin = 6'd11;
                5'd14: vib_qsin = 6'd11;  5'd15: vib_qsin = 6'd12;
                5'd16: vib_qsin = 6'd13;  5'd17: vib_qsin = 6'd13;
                5'd18: vib_qsin = 6'd14;  5'd19: vib_qsin = 6'd14;
                5'd20: vib_qsin = 6'd15;  5'd21: vib_qsin = 6'd15;
                5'd22: vib_qsin = 6'd16;  5'd23: vib_qsin = 6'd16;
                5'd24: vib_qsin = 6'd17;  5'd25: vib_qsin = 6'd17;
                5'd26: vib_qsin = 6'd17;  5'd27: vib_qsin = 6'd17;
                5'd28: vib_qsin = 6'd18;  5'd29: vib_qsin = 6'd18;
                5'd30: vib_qsin = 6'd18;
                default: vib_qsin = 6'd18;
            endcase
        end
    endfunction

    reg [23:0] vib_ph;

    wire        vib_half = vib_ph[23];
    wire [4:0]  vib_qi   = vib_ph[22] ? (5'd31 - vib_ph[21:17]) : vib_ph[21:17];
    wire [5:0]  vib_mag  = vib_qsin(vib_qi);
    wire signed [6:0] vib_smag =
        vib_half ? -$signed({1'b0, vib_mag}) : $signed({1'b0, vib_mag});
    wire signed [6:0] vib_slim = vib_smag;
    wire signed [6:0] vib_spos = vib_slim[6] ? -vib_slim : vib_slim;

    always @(posedge clk_sys or negedge srst_n) begin
        if (!srst_n) begin
            vib_ph  <= 24'd0;
            vib_d   <= 6'sd0;
            vib_abs <= 6'sd0;
        end else if (sample_tick) begin
            vib_ph  <= vib_ph + VIB_PH_INC[23:0];
            vib_d   <= vib_on ? vib_slim[5:0] : 6'sd0;
            vib_abs <= vib_on ? vib_spos[5:0] : 6'sd0;
        end
    end

    //------------------------------------------------------------------
    // lead note for the glide voice: the pad touched most recently
    //------------------------------------------------------------------
    reg [2:0] lead_key;
    integer   kk;

    always @(posedge clk_sys) begin
        if (!srst_n)
            lead_key <= 3'd0;
        else if (sample_tick) begin
            for (kk = 0; kk < VOICES; kk = kk + 1)
                if (key_rise[kk])
                    lead_key <= kk[2:0];       // highest-numbered new pad wins
        end
    end

    //  note_flat is packed 5 bits per voice (stride 5, matching osc_bank's
    //  note_flat[pvidx*5 +: 5]).  A stride of 4 here silently splices two
    //  adjacent notes together and the glide lands on the wrong pitch.
    //
    //  The slice is picked with an explicit 8:1 mux and then registered,
    //  rather than written as note_flat[lead_key*5 +: 5]:  the multiply is a
    //  real adder, and routing its result straight into inc_lut pushed the
    //  design from 111.8 MHz down to 108.3 MHz (0.3 % margin).
    reg [4:0] lead_note_c;
    always @(*) begin
        case (lead_key)
            3'd0:    lead_note_c = note_flat[0*5 +: 5];
            3'd1:    lead_note_c = note_flat[1*5 +: 5];
            3'd2:    lead_note_c = note_flat[2*5 +: 5];
            3'd3:    lead_note_c = note_flat[3*5 +: 5];
            3'd4:    lead_note_c = note_flat[4*5 +: 5];
            3'd5:    lead_note_c = note_flat[5*5 +: 5];
            3'd6:    lead_note_c = note_flat[6*5 +: 5];
            default: lead_note_c = note_flat[7*5 +: 5];
        endcase
    end

    reg [4:0] lead_note;
    always @(posedge clk_sys) begin
        if (!srst_n)          lead_note <= 5'd0;
        else if (sample_tick) lead_note <= lead_note_c;
    end

    // voice 0 plays the lead note while gliding, and is gated on as long as
    // anything is held, so the slide is audible on its own.
    wire [39:0] note_g = glide_en ? {note_t[39:5], lead_note} : note_t;
    wire [7:0]  gate_g = glide_en ? (gate | {7'd0, (|gate)}) : gate;

    //------------------------------------------------------------------
    // 32 oscillators (8 voices x 4 additive components)
    //------------------------------------------------------------------
    wire [16*VOICES-1:0] raw_flat;

    osc_bank #(
        .VOICES (VOICES),
        .NCOMP  (4)
    ) u_osc (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .fc       (fc),
        .note_flat(note_g),
        .timbre   (timbre_t),
        .oct      (oct_t),
        .wave_mode(wave_mode),
        .glide_en (glide_en),
        .vib_d    (vib_on ? vib_d : 6'sd0),
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
                .gate  (gate_g[gi]),
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
wire [15:0] mix_l;
wire [15:0] mix_r;
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
        .out_l    (mix_l),
        .out_r    (mix_r),
        .out_ok   (mix_ok)
    );

    //------------------------------------------------------------------
    // in-FPGA delay line (赛题拓展②: 延迟)
    //
    // Sits between the mixer and the final stage.  It adds exactly two
    // sample periods of latency whether it is on or off, and it publishes
    // its own 'valid' pulse so that audio_out stays phase locked to i2s_tx.
    // When all three effects are off the wet terms are forced to zero, so the
    // signal path is a pure constant delay and the audible result is unchanged.
    //------------------------------------------------------------------
    wire signed [15:0] echo_s;
    wire               echo_tick;

    fx_echo #(
        .DEPTH_LOG2 (13),        // 8192 samples = 169.9 ms of buffer
        .DELAY      (6000),      // echo   124.4 ms
        .RV1        (1784),      // reverb  37.0 ms
        .RV2        (2555),      // reverb  53.0 ms
        .RV3        (3424),      // reverb  71.0 ms
        .RV4        (4677),      // reverb  97.0 ms
        .CH_D       (1024),      // chorus  21.2 ms centre, +-64 samples
        .FB_SH      (2),         // 0.375 feedback
        .WET_SH     (2),         // echo wet 0.25
        .CH_WET_SH  (1),         // chorus wet 0.5
        .CH_LFO_INC (209)        // 0.60 Hz sweep
    ) u_echo (
        .clk    (clk_sys),
        .rst_n  (srst_n),
        .en     (mix_ok),
        .on     (echo_on),
        .rvb_on (rvb_on),
        .cho_on (cho_on),
        .din    ($signed(mix_out)),
        .dout   (echo_s),
        .en_o   (echo_tick)
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
        .mix_ok    (echo_tick),
        .mix_in    (echo_s),
        .vol_raw   (vol_t),
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
    // 实时频谱 (赛题拓展③)
    //
    // A 16-bin DFT evaluated on the final mono mix, one full 512-sample block
    // every 10.6 ms.  It is fed from the same node the waveform scope draws,
    // so the bars show exactly what is being heard.
    //------------------------------------------------------------------
    wire [63:0] spec_flat;

    spectrum16 #(
        .NLOG  (9),
        .NBINS (16)
    ) u_spec (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .en       (sample_tick),
        .xin      ($signed(mix_out)),
        .lvl_flat (spec_flat)
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
    // Lissajous pre-renderer
    //
    // Needs the LEFT and RIGHT sample of the same instant, and it reads all
    // 512 of them in one burst during vertical blanking -- which the display
    // buffer cannot serve because it is being scanned at the same time.  So a
    // second stereo history buffer is written in parallel (same data, same
    // address) and owned by the renderer.
    //
    // vblank comes straight off the pixel row counter: rows V_ACT..V_TOT-1 are
    // blanking, 14 lines x 525 px x DIV clk = 88200 clocks, plenty for the
    // 3584-clock update.
    //------------------------------------------------------------------
    wire [9:0]  tmg_x_w;
    wire        vblank_w;
    wire [8:0]  liss_haddr;
    wire [15:0] liss_hl, liss_hr;
    wire [15:0] liss_span;
    wire [15:0] liss_hr_unused;

    wave_buf u_wb_liss (
        .clk       (clk_sys),
        .wr_en     (scope_tick),
        .wr_addr   (wptr_w),
        .wr_data_l (mix_l),
        .wr_data_r (mix_r),
        .rd_addr   (liss_haddr),
        .rd_data_l (liss_hl),
        .rd_data_r (liss_hr)
    );

    liss_render u_liss (
        .clk       (clk_sys),
        .rst_n     (srst_n),
        .vblank    (vblank_w),
        .hist_addr (liss_haddr),
        .hist_l    (liss_hl),
        .hist_r    (liss_hr),
        .disp_addr (tmg_x_w[8:0]),
        .disp_span (liss_span)
    );

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
        .oct      (oct_t),
        .timbre   (timbre_t),
        .vol      (vol_t),
        .test_en  (test_en),
        .wave_mode(wave_mode),
        .fx       (fx_mode),
        .dmode    (dmode),
        .liss_span(liss_span),
        .tmg_x    (tmg_x_w),
        .tmg_vblank(vblank_w),
        .spec_flat(spec_flat),
        .vib_abs  (vib_abs),
        .lcd_dclk (lcd_dclk),
        .lcd_hs   (lcd_hs),
        .lcd_vs   (lcd_vs),
        .lcd_de   (lcd_de),
        .lcd_r    (lcd_r),
        .lcd_g    (lcd_g),
        .lcd_b    (lcd_b)
    );

endmodule
