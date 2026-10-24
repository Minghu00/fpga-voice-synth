//=============================================================================
// pll_sys.v  --  27 MHz -> 108 MHz system clock
//
//  rPLL: CLKOUT = CLKIN * (FBDIV_SEL+1) / [(IDIV_SEL+1) * ODIV_SEL]
//        VCO    = CLKIN * (FBDIV_SEL+1) /  (IDIV_SEL+1)
//
//  FCLKIN  = 27 MHz
//  IDIV_SEL= 0  -> /1        (IDIV divides the input)
//  FBDIV_SEL= 3 -> *4        CLKOUT = 27 * 4 / 1 = 108 MHz
//  ODIV_SEL= 8  -> VCO = 108 * 8 = 864 MHz  (in 500..1250)
//
//  IMPORTANT -- the vendor relation is NOT "CLKOUT = VCO / ODIV".
//  The Gowin tools (synthesis WARN EX0210, PnR WARN PA1019 and the STA
//  clock summary) all use
//      CLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1)
//      VCO    = CLKOUT * ODIV_SEL
//  i.e. ODIV_SEL only has to put the VCO inside 500..1250 MHz, it does not
//  divide CLKOUT.  Getting this backwards (FBDIV=31/ODIV=8) made the STA
//  analyse an 864 MHz clock.  Verified in impl/pnr/poly_synth.rpt.html:
//      u_pll/u_rpll/CLKOUT.default_gen_clk  Generated  9.259 ns  108.000 MHz
//
//  108 MHz was chosen because it divides both audio and video cleanly:
//    audio: 108e6 / 2240 = 48 214.2857 Hz  (I2S BCLK half = 35 clk -> 1.543 MHz)
//    video: 108e6 / 12   =  9.000 MHz       (480x272 panel pixel clock)
//
//  ***  NOTE  ***  The rPLL parameter semantics used by the LEGACY file
//  (IDIV=1/FBDIV=4/ODIV=8 -> VCO = 67.5 MHz) put the VCO far below the
//  400 MHz minimum, so that configuration was never trustworthy.
//  After the first build, VERIFY the real output frequency in
//  impl/pnr/poly_synth.rpt.txt before trusting the audio sample rate.
//=============================================================================
`timescale 1ns / 1ps

module pll_sys (
    input  wire clk27,      // 27 MHz from dock oscillator (H11)
    input  wire rst_n,
    output wire clk_sys,    // 108 MHz
    output wire locked
);

    wire clkoutp_unused;
    wire clkoutd_unused;
    wire clkoutd3_unused;

    // port list taken from
    //   <gowin>\IDE\data\hardware_core\gw2a\prim_syn.v
    //   rPLL (CLKOUT, CLKOUTP, CLKOUTD, CLKOUTD3, LOCK, CLKIN, CLKFB,
    //         FBDSEL, IDSEL, ODSEL, DUTYDA, PSDA, FDLY, RESET, RESET_P)
    rPLL #(
        .FCLKIN          ("27"),
        .IDIV_SEL        (0),          // /1
        .FBDIV_SEL       (3),          // *4   -> CLKOUT 108 MHz
        .ODIV_SEL        (8),          // VCO = 108 * 8 = 864 MHz
        .PSDA_SEL        ("0000"),
        .DUTYDA_SEL      ("1000"),
        .DYN_SDIV_SEL    (2),
        .DYN_IDIV_SEL    ("false"),
        .DYN_FBDIV_SEL   ("false"),
        .DYN_ODIV_SEL    ("false"),
        .DYN_DA_EN       ("false"),
        .CLKFB_SEL       ("internal"),
        .DEVICE          ("GW2A-18C")
    ) u_rpll (
        .CLKOUT  (clk_sys),
        .CLKOUTP (clkoutp_unused),
        .CLKOUTD (clkoutd_unused),
        .CLKOUTD3(clkoutd3_unused),
        .LOCK    (locked),
        .CLKIN   (clk27),
        .CLKFB   (1'b0),
        .FBDSEL  (6'b0),
        .IDSEL   (6'b0),
        .ODSEL   (6'b0),
        .DUTYDA  (4'b0),
        .PSDA    (4'b0),
        .FDLY    (4'b0),
        .RESET   (~rst_n),
        .RESET_P (1'b0)
    );

endmodule
