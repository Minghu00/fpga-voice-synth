//=============================================================================
// fx_echo.v  --  in-FPGA delay / echo line
//
//  赛题拓展② "在 FPGA 内部实现混响、延迟、合唱等音频效果" 里的「延迟」.
//
//  Structure
//  ---------
//      din ──┬──────────────────────────────┬──> + ──> dout      (dry + wet)
//            │                              │
//            │      ┌──────────────┐        │
//            └─────>│ ring buffer  │── d ──┤ * WET
//                   │ 8192 x 16    │        │
//                   └──────┬───────┘        │
//                          │ * FB           │
//                          └──> + din ──────┘ (written back)
//
//  The ring lives in BSRAM: 8192 x 16 bit = 8 blocks of the 46 available.
//  DEPTH = 8192 samples = 169.9 ms at 48 214.29 Hz; the read pointer trails
//  the write pointer by DELAY samples (6000 => 124.4 ms, a classic slap-back).
//
//  Timing
//  ------
//  Everything runs once per audio sample (en), so there are 2240 clocks of
//  slack per operation -- but the block is still written as a 2-deep pipeline
//  so that no multiplier is combinational between live audio nodes:
//
//      stage 0 (on en)   : latch din_q and rd_q, write din + fb into the ring
//      stage 1 (on en1)  : dout <= sat16(din_q + wet_of_rd_q)
//      en2               : dout is valid
//
//  audio_out.v consumes `dout` with `en2` as its mix_ok, so the dry path is
//  delayed by exactly 2 samples whether the echo is on or off.  That constant
//  offset is deliberate: the I2S phase must not jump when the effect is
//  switched, otherwise the transmitter would drop or repeat a sample.
//
//  When `on` = 0 the output is exactly `din` (wet term forced to 0) and the
//  ring keeps filling with the dry signal, so switching the echo on gives an
//  immediately correct delay line instead of a burst of silence.
//=============================================================================
`timescale 1ns / 1ps

module fx_echo #(
    parameter integer DEPTH_LOG2 = 13,      // 8192 samples = 169.9 ms
    parameter integer DELAY      = 6000,    // 124.4 ms
    // Both gains are powers of two on purpose: a shifter costs no LUT level,
    // while a real multiplier here sits between the ring buffer output and
    // its own write port and needed 8 logic levels (Fmax fell to 109.7 MHz).
    parameter integer FB_SH      = 2,       // feedback = 2^-FB + 2^-(FB+1) = 0.375
    parameter integer WET_SH     = 2,       // wet      = 2^-WET            = 0.25
    parameter integer FB_ENABLE  = 1        // 0 = tap only, no regeneration
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,           // one clk pulse per audio sample
    input  wire               on,
    input  wire signed [15:0] din,
    output reg  signed [15:0] dout,
    output wire               en_o          // dout is valid for one clk
);

    localparam integer NPTS = (1 << DEPTH_LOG2);

    //------------------------------------------------------------------
    // declarations first (some tools reject forward references)
    //------------------------------------------------------------------
    reg  [15:0] mem [0:NPTS-1];
    reg  [DEPTH_LOG2-1:0] waddr;
    reg  [15:0] mem_d;                  // BSRAM read data, 1 clk latency
    reg  signed [15:0] din_q;
    reg  signed [15:0] rd_q;
    reg                en1, en2;

    // Until the delay line has been filled there is nothing to echo.  On the
    // board the BSRAM happens to power up as zero, but a simulation starts it
    // as X and X would then propagate through the wet multiply into the DAC.
    // `primed` makes the behaviour well defined in both worlds: the tap reads
    // 0 for the first DELAY samples, exactly as a real delay line does.
    localparam integer PRIME = (DELAY > 0) ? DELAY : 1;
    reg  [15:0] prim_cnt;               // counts audio samples, saturates
    reg         primed;

    wire [DEPTH_LOG2-1:0] raddr = waddr - DELAY[DEPTH_LOG2-1:0];

    function signed [15:0] sat16;
        input signed [16:0] x;
        begin
            if (x > 17'sd32767)
                sat16 = 16'sh7FFF;
            else if (x < -17'sd32768)
                sat16 = 16'sh8000;
            else
                sat16 = x[15:0];
        end
    endfunction

    // Feedback and wet gains are pure shifts, so the only arithmetic between
    // the BSRAM output and its write port is one 17-bit add and the clamp.
    wire signed [15:0] dly      = primed ? mem_d : 16'sd0;  // delayed sample
    wire signed [15:0] fb_gain  = FB_ENABLE ? ((dly >>> FB_SH) + (dly >>> (FB_SH + 1)))
                                            : 16'sd0;
    wire signed [16:0] fb_sum   = din + {{1{fb_gain[15]}}, fb_gain};

    // wet term is gated by `on`; when off it is exactly zero, so the output
    // becomes a pure (2-sample delayed) copy of the input.
    wire signed [15:0] wet_gain = rd_q >>> WET_SH;
    wire signed [16:0] wet_term = on ? {{1{wet_gain[15]}}, wet_gain} : 17'sd0;
    wire signed [16:0] wet_sum  = din_q + wet_term;

    //------------------------------------------------------------------
    // BSRAM + its pointers.  Read every clk, write only on `en` -- the same
    // shape as wave_buf.v, which infers cleanly in Gowin.  No async reset:
    // a BSRAM write port cannot have one, so use an initial value instead.
    //------------------------------------------------------------------
    initial begin
        waddr    = 0;
        din_q    = 0;
        rd_q     = 0;
        prim_cnt = 0;
        primed   = 1'b0;
    end

    always @(posedge clk) begin
        mem_d <= mem[raddr];
        if (en) begin
            mem[waddr] <= sat16(fb_sum);
            din_q      <= din;
            rd_q       <= dly;
            waddr      <= waddr + 1'b1;
            if (!primed) begin
                if (prim_cnt >= PRIME[15:0] - 16'd1)
                    primed <= 1'b1;
                else
                    prim_cnt <= prim_cnt + 16'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout <= 16'sd0;
            en1  <= 1'b0;
            en2  <= 1'b0;
        end else begin
            en1 <= en;
            en2 <= en1;
            if (en1)
                dout <= sat16(wet_sum);
        end
    end

    assign en_o = en2;

endmodule
