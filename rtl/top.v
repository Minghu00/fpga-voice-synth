//=============================================================================
// top.v  --  FPGA real-time multi-timbre synthesiser engine
//            Tang Primer 20K (GW2A-18C) + Dock 3709/3714
//
//  信号链
//      TTP229 16键触摸 --2wire--> keymap --> 16 voice x 4 加法分量
//        --> 16 x ADSR --> mixer16 --> I2S --> MAX98357 功放模块
//
//  时钟
//      clk27 (H11) --rPLL  x16 /4--> clk_sys = 108 MHz
//      每音频帧 2240 clk  ->  fs = 48 214.2857 Hz
//      I2S 16 bit/声道, BCLK_HALF = 35 clk  ->  BCLK = 1.5429 MHz
//
//  管脚（详见 constraints/pinmap_v2.cst，全部来自 Dock 3714 原理图根页）
//      clk27     H11
//      rst_n     T10   (FPGA_RST 复位键, 1.5V bank)
//      tp_scl    P8    (J14-7  MIC_DAT0)
//      tp_sdo    T8    (J14-8  MIC_DAT1)
//      i2s_bclk  R8    (J14-9  MIC_DAT2)
//      i2s_lrclk T7    (J14-10 MIC_DAT3)
//      i2s_din   P6    (J14-11 MIC_WS)
//=============================================================================
`timescale 1ns / 1ps

module top #(
    // TTP229 timing (production values; the testbench overrides them)
    parameter integer INIT_CLK   = 21_600_000,
    parameter integer POLL_CLK   = 216_000,
    parameter integer SCL_HALF   = 108,
    parameter integer ACTIVE_LOW = 1,
    // envelope rates (production values; the testbench overrides them)
    parameter integer ATT_STEP  = 340,
    parameter integer DEC_STEP  = 2,
    parameter integer REL_STEP  = 6,
    parameter integer SUSTAIN   = 39_321
) (
    input  wire clk27,
    input  wire rst_n,
    input  wire tp_sdo,
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

    localparam integer VOICES = 16;

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

    wire [15:0] gate;
    wire [79:0] note_flat;
    wire [1:0]  oct;
    wire [1:0]  timbre;

    keymap u_keymap (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .en       (sample_tick),
        .key_raw  (key_raw),
        .gate     (gate),
        .note_flat(note_flat),
        .oct      (oct),
        .timbre   (timbre)
    );

    //------------------------------------------------------------------
    // 64 oscillators (16 voices x 4 additive harmonics)
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
    // mixdown
    //------------------------------------------------------------------
    wire [15:0] mix_out;

    mixer16 #(
        .VOICES   (VOICES),
        .MIX_SHIFT(4)
    ) u_mixer (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .fc       (fc),
        .mix_ph   (mix_ph),
        .raw_flat (raw_flat),
        .env_flat (env_flat),
        .out      (mix_out)
    );

    //------------------------------------------------------------------
    // I2S out (mono engine duplicated to L/R)
    //------------------------------------------------------------------
    i2s_tx #(
        .BCLK_HALF (35)
    ) u_i2s (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .fc       (fc),
        .sample_l (mix_out),
        .sample_r (mix_out),
        .bclk     (i2s_bclk),
        .lrclk    (i2s_lrclk),
        .din      (i2s_din)
    );

    //------------------------------------------------------------------
    // latency meter (read via a hierarchical reference from the testbench,
    // no extra top-level pin needed)
    //------------------------------------------------------------------
    wire [31:0] lat_val;
    wire [31:0] lat_max;
    wire        lat_valid;

    lat_counter u_lat (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .fc       (fc),
        .key_raw  (key_raw),
        .lat_val  (lat_val),
        .lat_max  (lat_max),
        .lat_valid(lat_valid)
    );

    //------------------------------------------------------------------
    // LCD performance display
    //   the history RAM is written once per audio frame with the mixed
    //   sample; everything on screen is derived from it plus the live
    //   envelope / key state, so the display costs one BSRAM and no
    //   frame buffer.
    //------------------------------------------------------------------
    reg [8:0] wptr;
    always @(posedge clk_sys) begin
        if (!srst_n)
            wptr <= 9'd0;
        else if (sample_tick)
            wptr <= wptr + 9'd1;
    end

    lcd_panel u_lcd (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .wr_en    (sample_tick),
        .wr_addr  (wptr),
        .wr_data  (mix_out),
        .env_flat (env_flat),
        .key_raw  (key_raw),
        .lcd_dclk (lcd_dclk),
        .lcd_hs   (lcd_hs),
        .lcd_vs   (lcd_vs),
        .lcd_de   (lcd_de),
        .lcd_r    (lcd_r),
        .lcd_g    (lcd_g),
        .lcd_b    (lcd_b)
    );

endmodule