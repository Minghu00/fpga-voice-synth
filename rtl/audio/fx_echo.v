//=============================================================================
// fx_echo.v  --  in-FPGA delay / reverb / chorus unit
//
//  赛题拓展② "在 FPGA 内部实现混响、延迟、合唱等音频效果".
//  三个效果共用一条 8192 x 16 的环形延迟线（8 块 BSRAM），因为它们的
//  区别只是**从环上哪个位置取、取几路、加多少反馈**：
//
//     效果        抽头                    用途
//     延迟(echo)  DELAY   = 6000 (124.4 ms)   单次 slap-back
//     混响(reverb) RV1..RV4 = 1784/2555/3424/4677 (37.0/53.0/71.0/97.0 ms)
//                                          四路梳状叠加 + 环内再生
//     合唱(chorus) CH_D ± 64 (21.2 ms 中心)   单路 + 0.6 Hz 三角波调制
//
//  Structure
//  ---------
//      din ──┬────────────────────────────────────┬──> + ──> dout
//            │                                    │
//            │      ┌──────────────────────┐      │
//            └─────>│ ring 8192 x 16 (BSRAM)│      │
//                   └──────┬───────────────┘      │
//            6 路时分复用读 │                      │
//            echo/4xreverb/chorus ── 各自增益 ─────┤ * WET
//                          │ * FB                 │
//                          └──> + din ──> 写回 ────┘
//
//  Why six taps but only one read port
//  -----------------------------------
//  A BSRAM has one read port, and instantiating six copies of the ring would
//  cost 48 blocks (the whole budget is 46).  Instead the taps are read one per
//  clock: `en` fires once every 2240 clocks, and the whole sweep takes 15, so
//  there is 149x headroom.  Only the *address* is sequenced; the data path is
//  a single accumulator that is read-modify-written once per sample.
//
//  Timing history (do not "simplify" this away)
//  -------------------------------------------
//  A single clock from the BSRAM output through the clamp back into its own
//  write port left 0.014 ns of margin (Fmax 108.3 MHz).  The write path is
//  therefore split over two registers, and every tap sample is captured into
//  a flop before any arithmetic touches it.  Total cost: 15 clocks per sample
//  out of 2240 -- free -- and Fmax back to 116.5 MHz.
//
//  Constant latency
//  ----------------
//  `dout` is a fixed number of clocks behind `en` no matter which effects are
//  on, and `en_o` marks exactly that sample.  The I2S phase must never jump
//  when an effect is switched, otherwise the transmitter drops or repeats a
//  sample.
//
//  Priming
//  -------
//  Until the line has been filled there is nothing to echo.  On the board the
//  BSRAM powers up as zero, but a simulation starts it as X and X would then
//  propagate through the wet path into the DAC.  `primed` makes both worlds
//  behave like a real delay line: the taps read 0 for the first PRIME samples.
//=============================================================================
`timescale 1ns / 1ps

module fx_echo #(
    parameter integer DEPTH_LOG2 = 13,      // 8192 samples = 169.9 ms
    parameter integer DELAY      = 6000,    // echo      124.4 ms
    parameter integer RV1        = 1784,    // reverb #1  37.0 ms
    parameter integer RV2        = 2555,    // reverb #2  53.0 ms
    parameter integer RV3        = 3424,    // reverb #3  71.0 ms
    parameter integer RV4        = 4677,    // reverb #4  97.0 ms
    parameter integer CH_D       = 1024,    // chorus centre 21.2 ms
    // Both gains are powers of two on purpose: a shifter costs no LUT level,
    // while a real multiplier here sits between the ring buffer output and
    // its own write port and needed 8 logic levels (Fmax fell to 109.7 MHz).
    parameter integer FB_SH      = 2,       // feedback = 2^-FB + 2^-(FB+1) = 0.375
    parameter integer WET_SH     = 2,       // echo  wet = 2^-WET    = 0.25
    parameter integer FB_ENABLE  = 1,       // 0 = tap only, no regeneration
    // reverb tap weights (all pure shifts, sum = 0.5625)
    parameter integer RV1_SH     = 2,       // 0.2500
    parameter integer RV2_SH     = 3,       // 0.1250
    parameter integer RV3_SH     = 3,       // 0.1250
    parameter integer RV4_SH     = 4,       // 0.0625
    parameter integer CH_WET_SH  = 1,       // chorus wet = 0.5
    parameter integer CH_LFO_INC = 209      // 0.60 Hz at 48 214.29 Hz (24-bit)
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,           // one clk pulse per audio sample
    input  wire               on,           // echo
    input  wire               rvb_on,       // reverb
    input  wire               cho_on,       // chorus
    input  wire signed [15:0] din,
    output reg  signed [15:0] dout,
    output wire               en_o          // dout is valid for one clk
);

    localparam integer NPTS  = (1 << DEPTH_LOG2);
    localparam integer NTAP  = 6;           // echo + 4 reverb + chorus
    localparam integer TCYC  = NTAP + 2;    // 8 : last collect clock
    localparam integer TFIN  = TCYC;        // 8 : final sum / output / write

    // Until the line has been filled there is nothing to echo.  DELAY is the
    // longest tap (6000 > RV4 = 4677), so priming to DELAY covers every tap.
    localparam integer PRIME = (DELAY > 0) ? DELAY : 1;
    localparam [DEPTH_LOG2-1:0] CH_LO = CH_D[DEPTH_LOG2-1:0] - 8'd64;

    //------------------------------------------------------------------
    // declarations first (some tools reject forward references)
    //------------------------------------------------------------------
    reg  [15:0] mem [0:NPTS-1];
    reg  [DEPTH_LOG2-1:0] waddr;
    reg  [15:0] mem_d;                  // BSRAM read data, 1 clk latency
    reg  [DEPTH_LOG2-1:0] raddr;

    reg  signed [15:0] din_q;           // dry, for the output sum
    reg  signed [15:0] din_d;           // dry, for the write-back sum
    reg  [DEPTH_LOG2-1:0] wbase;        // address this sample is written to

    // tap sequencer
    reg  [3:0]  tc;
    reg         run;
    wire [2:0]  ti_issue = tc[2:0];        // tap being issued this cycle
    wire [2:0]  ti_coll  = tc[2:0] - 3'd2; // tap being collected this cycle

    // tap captures
    reg  signed [15:0] t0q;             // echo tap
    reg  signed [17:0] racc;            // reverb tap sum
    reg  signed [15:0] chq;             // chorus tap

    // write-back pipeline (sum -> register -> BSRAM write)
    reg  signed [15:0] wq;
    reg  [DEPTH_LOG2-1:0] wq_ad;
    reg                wr_pend;

    // chorus LFO
    reg  [23:0] lfo;

    // priming
    reg  [15:0] prim_cnt;
    reg         primed;

    //------------------------------------------------------------------
    // tap address select.  Only the address is sequenced, never the data.
    //------------------------------------------------------------------
    reg [DEPTH_LOG2-1:0] dsel;
    wire [7:0] lfo_tri = lfo[23] ? ~lfo[22:15] : lfo[22:15];   // 0..255
    wire [DEPTH_LOG2-1:0] ch_dly = CH_LO + lfo_tri[7:1];   // CH_D-64 .. CH_D+63

    always @(*) begin
        case (ti_issue)
            3'd0: dsel = DELAY[DEPTH_LOG2-1:0];
            3'd1: dsel = RV1[DEPTH_LOG2-1:0];
            3'd2: dsel = RV2[DEPTH_LOG2-1:0];
            3'd3: dsel = RV3[DEPTH_LOG2-1:0];
            3'd4: dsel = RV4[DEPTH_LOG2-1:0];
            default: dsel = ch_dly;
        endcase
    end

    //------------------------------------------------------------------
    // arithmetic helpers
    //------------------------------------------------------------------
    function signed [15:0] sat16;
        input signed [17:0] x;
        begin
            if (x > 18'sd32767)
                sat16 = 16'sh7FFF;
            else if (x < -18'sd32768)
                sat16 = 16'sh8000;
            else
                sat16 = x[15:0];
        end
    endfunction

    // every tap sample is gated by `primed` so an uninitialised BSRAM never
    // leaks X into the audio path
    wire signed [15:0] dly = primed ? mem_d : 16'sd0;

    // reverb sum, saturated back to 16 bit for the feedback / wet paths
    wire signed [15:0] rvb_s = sat16(racc);

    // which signal feeds the regeneration
    wire signed [15:0] fb_src = on   ? t0q  :
                                rvb_on ? rvb_s : 16'sd0;

    wire signed [15:0] fbg_new = FB_ENABLE ? ((fb_src >>> FB_SH) + (fb_src >>> (FB_SH + 1)))
                                           : 16'sd0;

    //-------------------------------------------------------------------------
    // output wet sum, built only from flops -> one adder tree, no BSRAM in the
    // path.  When an effect is off its term is exactly zero, so switching it
    // off restores a bit-exact dry copy.
    //-------------------------------------------------------------------------
    wire signed [15:0] echo_wet = on    ? (t0q >>> WET_SH)    : 16'sd0;
    wire signed [15:0] rvb_wet  = rvb_on ? rvb_s               : 16'sd0;
    wire signed [15:0] cho_wet  = cho_on ? (chq >>> CH_WET_SH) : 16'sd0;
    // NOTE -- do NOT write this as
    //     {din_q[15], din_q} + {echo_wet[15], echo_wet} + ...
    // A concatenation is ALWAYS UNSIGNED in Verilog, so {din_q[15], din_q}
    // is a 17-bit UNSIGNED number: for a negative sample it becomes 131061
    // and the sum saturates to +32767.  That produced a full-scale positive
    // DC on the I2S line for every negative half cycle -- the amplifier then
    // output a constant rail with the real signal only poking through on
    // positive samples, which is heard as a rough tremble.
    // Every operand below is declared SIGNED 16 bit; assigning into a signed
    // 18-bit net makes Verilog sign-extend each of them.
    wire signed [17:0] wet_sum = din_q + echo_wet + rvb_wet + cho_wet;

    // write-back sum built from registers only (din_d / fbg_new)
    wire signed [17:0] wb_sum = din_d + fbg_new;

    //------------------------------------------------------------------
    // BSRAM + tap sequencer.  No async reset on the memory: a BSRAM write
    // port cannot have one, so the pipeline flops use an initial value.
    //------------------------------------------------------------------
    initial begin
        waddr    = 0;
        raddr    = 0;
        din_q    = 0;
        din_d    = 0;
        wbase    = 0;
        tc       = 0;
        run      = 1'b0;
        t0q      = 0;
        racc     = 0;
        chq      = 0;
        wq       = 0;
        wq_ad    = 0;
        wr_pend  = 1'b0;
        lfo      = 0;
        prim_cnt = 0;
        primed   = 1'b0;
    end

    // tc counts 0..TFIN.  Each cycle issues the read for tap tc and collects
    // the read of tap tc-1, because the BSRAM output appears one clock after
    // its address was sampled.  That overlap keeps the sweep at NTAP+2 clocks.
    always @(posedge clk) begin
        mem_d <= mem[raddr];

        //-----------------------------------------------------------------
        // sample boundary : latch the dry sample, start the tap sweep
        //-----------------------------------------------------------------
        if (en) begin
            din_q <= din;
            din_d <= din;
            wbase <= waddr;
            waddr <= waddr + 1'b1;
            racc  <= 18'sd0;
            tc    <= 4'd0;
            run   <= 1'b1;
            lfo   <= lfo + CH_LFO_INC[23:0];
            if (!primed) begin
                if (prim_cnt >= PRIME[15:0] - 16'd1)
                    primed <= 1'b1;
                else
                    prim_cnt <= prim_cnt + 16'd1;
            end
        end else if (run) begin
            tc <= tc + 4'd1;
            if (tc == TFIN) run <= 1'b0;
        end

        //-----------------------------------------------------------------
        // tap sweep
        //-----------------------------------------------------------------
        if (run) begin
            // issue the address of tap `tc` (range 0..NTAP-1)
            if (tc < NTAP)
                raddr <= wbase - dsel;

            // collect tap `tc-1`: mem_d now carries what was issued last cycle
            if (tc >= 4'd2) begin
                case (ti_coll)
                    3'd0: t0q  <= dly;
                    3'd1: racc <= racc + (dly >>> RV1_SH);
                    3'd2: racc <= racc + (dly >>> RV2_SH);
                    3'd3: racc <= racc + (dly >>> RV3_SH);
                    3'd4: racc <= racc + (dly >>> RV4_SH);
                    default: chq <= dly;
                endcase
            end
        end

        //-----------------------------------------------------------------
        // final cycle : write-back request (registered, so the BSRAM write
        // port is driven by flops and never by its own output)
        //-----------------------------------------------------------------
        if (run && (tc == TFIN)) begin
            wq      <= sat16(wb_sum);
            wq_ad   <= wbase;
            wr_pend <= 1'b1;
        end else begin
            wr_pend <= 1'b0;
        end

        if (wr_pend)
            mem[wq_ad] <= wq;
    end

    //-------------------------------------------------------------------------
    // output register.  `sum_q` is captured on the final sweep cycle and then
    // driven out one clock later, together with en_o, so the consumer sees the
    // sample and its valid flag on the same edge regardless of effect settings.
    //-------------------------------------------------------------------------
    reg en_o_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout   <= 16'sd0;
            en_o_r <= 1'b0;
        end else begin
            en_o_r <= run && (tc == TFIN);
            if (run && (tc == TFIN))
                dout <= sat16(wet_sum);
        end
    end

    assign en_o = en_o_r;

endmodule
