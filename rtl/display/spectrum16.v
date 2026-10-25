//============================================================================
//  spectrum16.v -- 16-bin real-time spectrum analyser for the scope display
//
//  WHY NOT A RADIX-2 FFT
//  ---------------------
//  A framebuffer-free scanline display only needs 16 numbers, so a full FFT
//  would be a poor use of 20736 LUTs.  This block evaluates the DFT directly
//  at 16 fixed bins:
//
//      Re_k = sum_{n<N} x[n] * cos(2*pi*k*n/N)
//      Im_k = sum_{n<N} x[n] * sin(2*pi*k*n/N)
//
//  Every bin keeps its own 9-bit phase accumulator that simply adds k every
//  sample, so cos/sin come straight out of ONE 512-entry sine table.  The
//  table is instantiated twice so both reads can be issued in the same clock;
//  a single-port RAM would need two.
//
//    cost: 2 BSRAM (512x16 each), 2 DSP multipliers, ~ 150 flops
//    rate: 5 clocks per bin * 16 bins = 80 clocks per audio sample, out of
//          the 2240 a frame allows -> 3.6 % of the frame budget
//
//  TWO THINGS THAT MUST STAY EXACTLY AS WRITTEN (each cost a debug round)
//  ---------------------------------------------------------------------
//  1. cos(p) = sin(p + N/4).  Using N/2 makes the "cosine" equal to -sin(p),
//     so Re and Im become the same number, the transform degenerates and a
//     single tone smears over every bin.
//  2. Both the table read and the multiply are NON-BLOCKING, so each stage
//     needs its own clock.  Collapsing the "table output updates" cycle and
//     the "latch sv/cv" cycle captures the PREVIOUS bin's sine -- same smear.
//
//  BIN MAP
//  -------
//  N = 512 at fs = 48214.2857 Hz  ->  94.174 Hz per bin.
//  Bin numbers k run 1..16 (k = 0 would be DC) so they cover 94 Hz .. 1.507 kHz,
//  which brackets the range the keys can play (C4 = 261.6 Hz .. C6 = 1046 Hz).
//  Storage slot b = k-1, so lvl_flat[b*4 +: 4] holds bin number k = b+1.
//
//  LEVEL
//  -----
//  For a full-scale sine sitting on a bin centre  Re = A*N/2 = 32767*256, so
//  |Re|+|Im| reaches ~8.4e6 (24 bits).  The bar height uses the POSITION OF
//  THE HIGHEST SET BIT of that magnitude, a log2 scale: 16 levels span 96 dB
//  and every level is 6 dB.  msb = 23 (full scale) maps to level 15; anything
//  below msb = 8 is level 0, which keeps the noise floor off the screen.
//
//  PUBLISHING
//  ----------
//  A block ends after N enables.  Then 16 clocks walk the bins once more to
//  convert |Re|+|Im| into a 4-bit level and to clear the accumulators, so the
//  next block starts from zero without a second driver on re[]/im[].
//============================================================================
`timescale 1ns / 1ps

module spectrum16 #(
    parameter integer NLOG  = 9,            // N = 2^NLOG = 512
    parameter integer NBINS = 16
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire               en,           // 1 = new audio sample on `xin`
    input  wire signed [15:0] xin,

    // 16 levels, 4 bits each, bin number k in [(k-1)*4 +: 4].
    //  Registered; stable for a whole block (512 / 48214.2857 = 10.62 ms).
    output reg  [4*NBINS-1:0] lvl_flat
);
    localparam integer N      = 1 << NLOG;  // 512
    localparam integer NQUART = N / 4;      // 128 = 90 degrees -> cos
    localparam [4:0]   LASTB  = NBINS[4:0] - 5'd1;
    localparam [15:0]  NVAL   = N[15:0];

    //------------------------------------------------------------------
    // two copies of the sine table so sin and cos can be read in one clock
    //------------------------------------------------------------------
    reg [15:0] sin_re [0:N-1];
    reg [15:0] sin_im [0:N-1];
    initial begin
        $readmemh("rtl/display/spectrum_sin.mem", sin_re);
        $readmemh("rtl/display/spectrum_sin.mem", sin_im);
    end

    reg  [8:0]  ra_re, ra_im;
    //  NOTE: there is deliberately no `rd_re <= sin_re[ra_re]` register here.
    //  The read has to happen inside the FSM, one clock AFTER the address is
    //  issued.  An unconditional `rd_re <= table[ra]` block updates rd_re on
    //  the same edge that a `sv <= rd_re` would read it, so sv captured the
    //  PREVIOUS address's sample -- every bin then correlated against its
    //  neighbour's frequency and a single tone lit the whole display.

    //------------------------------------------------------------------
    // per-bin state
    //------------------------------------------------------------------
    reg  [8:0]        ph [0:NBINS-1];       // 0..N-1
    reg signed [31:0] re [0:NBINS-1];
    reg signed [31:0] im [0:NBINS-1];

    //------------------------------------------------------------------
    // sequencer
    //------------------------------------------------------------------
    reg        pub;                         // 1 = publishing a finished block
    reg        run;                         // 1 = a sample is being swept
    reg  [2:0] step;                        // 0..4 inside one bin
    reg  [4:0] bctr;                        // bin slot while sweeping
    reg  [4:0] pctr;                        // bin slot while publishing
    reg        pphase;                      // 0 = find ref, 1 = write levels
    reg  [4:0] msb_q [0:NBINS-1];           // per-bin msb of the finished block
    reg  [4:0] ref;                         // msb of the loudest bin this block
    //  TIMING.  `msb` is combinational from the accumulator storage, through a
    //  32-bit add and a 32-bit priority encoder.  Comparing it against `ref`
    //  in the same clock put that whole chain in series with the clock enable
    //  of `ref`, which measured -7.6 ns of slack (Fmax 59 MHz).  `msb_d` is
    //  the registered copy, so the compare only sees two flip-flops.
    reg  [4:0] msb_d;                       // msb of the previous publish slot
    reg  [31:0] are_q, aim_q;               // |Re|, |Im| registered
    reg  [31:0] mag_q;                      // |Re|+|Im|, registered
    reg  [1:0]  pcnt;                       // 0 abs, 1 add, 2 encode
    reg         ptail;                      // one extra cycle to fold in slot LASTB
    wire [5:0] dd = {1'b0, ref} - {1'b0, msb_q[pctr]};   // 6 dB steps below ref
    reg  [15:0] scnt;                       // samples in this block
    reg signed [15:0] xq;                   // sample being analysed
    reg signed [15:0] sv, cv;               // sin / cos of the current bin
    reg signed [31:0] pS, pC;               // the two products, pre-scaled

    wire [8:0] p_k   = ph[bctr];
    wire [8:0] p_cos = p_k + NQUART[8:0];
    wire [4:0] k1    = bctr + 5'd1;         // bin number k = slot + 1

    //  Two shared multipliers.  They sample xq against the sin/cos latched on
    //  the previous clock, so the products are ready for the accumulate step.
    //
    //  THE >>10 IS NOT COSMETIC.  A full-scale tone sitting on a bin centre
    //  makes one product 32767*32767 = 2^30, and 512 of those add up to 2^39,
    //  which a 32-bit accumulator cannot hold.  Worse, an OFF-centre tone has
    //  partial sums up to 2^36 (Dirichlet kernel), so the wrap happened for
    //  every bin -- the first version showed a single note smeared across the
    //  whole display.  Scaling the product by 2^-10 keeps the matched bin at
    //  2^28 and the worst-case leakage below 2^27.  The level formula below
    //  is calibrated for this scale.
    //  TRIANGULAR WINDOW.  Without it a single note is not a single bar: the
    //  rectangular window splatters an off-centre tone across every bin (the
    //  Dirichlet kernel falls off as 1/df, so with a 94 Hz bin and C4 sitting
    //  2.78 bins up, even bin 16 still saw -22 dB -> the whole display lit up).
    //  A triangle drops the far sidelobes by about 13 dB and costs nothing:
    //  it is just the sample counter folded at the halfway point.  Peak gain
    //  1.0, mean gain 0.5, hence the level calibration below.
    wire [7:0] win = scnt[8] ? (8'd255 - scnt[7:0]) : scnt[7:0];

    //  The product MUST have its own 24-bit net.  In a context-determined
    //  expression like   xq <= xin * win >>> 8;   the multiply is sized by the
    //  16-bit assignment target, not by the sum of the operand widths, so the
    //  top 8 bits are thrown away before the shift and every level comes out
    //  10 bits (60 dB) too low.  Cost a debug round; do not "simplify" this.
    wire signed [23:0] xwin = $signed(xin) * $signed({1'b0, win});

    always @(posedge clk) begin
        pS <= ($signed(xq) * $signed(sv)) >>> 10;
        pC <= ($signed(xq) * $signed(cv)) >>> 10;
    end

    //------------------------------------------------------------------
    // highest-set-bit of a 32-bit magnitude -> 0..31
    //------------------------------------------------------------------
    function [4:0] msb32;
        input [31:0] v;
        integer i;
        begin
            msb32 = 5'd0;
            for (i = 0; i < 32; i = i + 1)
                if (v[i]) msb32 = i[4:0];
        end
    endfunction

    //  NOTE: the absolute value must span all 32 bits.  Taking only [24:0]
    //  silently truncated any bin louder than 2^25 and pinned it to one
    //  wrong level -- that bug made full scale and half scale both read 11.
    wire signed [31:0] re_p = re[pctr];
    wire signed [31:0] im_p = im[pctr];
    wire        [31:0] a_re = re_p[31] ? (~re_p + 32'd1) : re_p;
    wire        [31:0] a_im = im_p[31] ? (~im_p + 32'd1) : im_p;
    wire        [31:0] mag  = a_re + a_im;
    wire        [4:0]  msb     = msb32(mag);      // combinational, kept for probes
    wire        [4:0]  msb_enc = msb32(mag_q);    // registered input -> short path

    //------------------------------------------------------------------
    // AUTOMATIC LEVEL CONTROL
    //
    // A fixed threshold does not work here: the mix level after MIX_SHIFT is
    // only a few thousand counts, so an absolute threshold either shows
    // nothing or saturates everything, and turning the volume down blanks the
    // display.  Instead the block's own peak bin becomes the reference and the
    // bars are drawn on a 3 dB/level scale relative to it:
    //
    //     level = 15 - (ref - msb)*2      (1 msb = 6 dB, so 2 levels per msb)
    //
    // Anything more than 45 dB below the peak reads 0, which is what makes
    // window sidelobes and the quantisation floor go dark.  Publishing
    // therefore needs two passes: the first finds ref and stores each bin's
    // msb, the second turns those into levels.
    //------------------------------------------------------------------
    wire        [3:0]  lvl  = (ref < 5'd8)            ? 4'd0 :
                              (dd >= 6'd8)            ? 4'd0 :
                              (4'd15 - {dd[2:0], 1'b0});

    integer b;
    always @(posedge clk) begin
        if (!rst_n) begin
            pub      <= 1'b0;
            run      <= 1'b0;
            step     <= 3'd0;
            bctr     <= 5'd0;
            pctr     <= 5'd0;
            pphase   <= 1'b0;
            ref      <= 5'd0;
            msb_d    <= 5'd0;
            are_q    <= 32'd0;
            aim_q    <= 32'd0;
            mag_q    <= 32'd0;
            pcnt     <= 2'd0;
            ptail    <= 1'b0;
            scnt     <= 16'd0;
            xq       <= 16'sd0;
            sv       <= 16'sd0;
            cv       <= 16'sd0;
            ra_re    <= 9'd0;
            ra_im    <= NQUART[8:0];
            lvl_flat <= {4*NBINS{1'b0}};
            for (b = 0; b < NBINS; b = b + 1) begin
                ph[b] <= 9'd0;              // first sample of a block uses n=0
                re[b] <= 32'sd0;
                im[b] <= 32'sd0;
            end
        end else if (pub) begin
            //----------------------------------------------------------
            // publishing: two passes of 16 clocks
            //   phase 0: record each bin's msb and find the block peak
            //   phase 1: turn (msb, ref) into the 4-bit bar level
            //----------------------------------------------------------
            if (!pphase) begin
                //  TWO CYCLES PER SLOT.  Cycle 0 registers |Re|+|Im|; cycle 1
                //  runs the priority encoder on that register.  Doing both in
                //  one clock put storage -> abs -> add -> encoder -> CE of `ref`
                //  in series and measured -4.25 ns (Fmax 74 MHz).
                if (ptail) begin
                    // fold in slot LASTB, whose msb is still in msb_d
                    if (msb_d > ref) ref <= msb_d;
                    ptail  <= 1'b0;
                    pphase <= 1'b1;
                    pctr   <= 5'd0;
                end else if (pcnt == 2'd0) begin
                    // cycle 0: |Re| and |Im| (two conditional negates)
                    are_q <= a_re;
                    aim_q <= a_im;
                    pcnt  <= 2'd1;
                end else if (pcnt == 2'd1) begin
                    // cycle 1: the 32-bit sum
                    mag_q <= are_q + aim_q;
                    pcnt  <= 2'd2;
                end else begin
                    // cycle 2: priority encoder on a register
                    pcnt        <= 2'd0;
                    msb_q[pctr] <= msb_enc;
                    msb_d       <= msb_enc;
                    if (msb_d > ref) ref <= msb_d;
                    if (pctr == LASTB) ptail <= 1'b1;
                    else               pctr  <= pctr + 5'd1;
                end
            end else begin
                lvl_flat[pctr*4 +: 4] <= lvl;
                re[pctr] <= 32'sd0;
                im[pctr] <= 32'sd0;
                if (pctr == LASTB) begin
                    pub     <= 1'b0;
                    pphase  <= 1'b0;
                    ref     <= 5'd0;
                    pctr    <= 5'd0;
                    pcnt    <= 2'd0;
                    ptail   <= 1'b0;
                end else begin
                    pctr <= pctr + 5'd1;
                end
            end
        end else if (en) begin
            //----------------------------------------------------------
            // a new audio sample: latch it and start a fresh bin sweep
            //----------------------------------------------------------
            xq   <= xwin[23:8];
            run  <= 1'b1;
            step <= 3'd0;
            bctr <= 5'd0;
            scnt <= scnt + 16'd1;
        end else if (run) begin
            //  Five clocks per bin.  See the header: every stage needs its
            //  own cycle because the table read and the multiply are both
            //  non-blocking.
            case (step)
                3'd0: begin                 // issue sin/cos addresses
                    ra_re <= p_k;
                    ra_im <= p_cos;
                    step  <= 3'd1;
                end
                3'd1: begin                 // let ra_re / ra_im settle
                    step <= 3'd2;
                end
                3'd2: begin                 // one clock after the address:
                    sv   <= sin_re[ra_re];  // both reads complete here, so
                    cv   <= sin_im[ra_im];  // sv/cv hold THIS bin's values
                    step <= 3'd3;
                end
                3'd3: begin                 // pS / pC are produced here
                    step <= 3'd4;
                end
                default: begin              // accumulate, advance, next bin
                    re[bctr] <= re[bctr] + pS;
                    im[bctr] <= im[bctr] - pC;
                    ph[bctr] <= ph[bctr] + k1;
                    step     <= 3'd0;
                    if (bctr == LASTB) begin
                        bctr <= 5'd0;
                        run  <= 1'b0;
                        if (scnt >= NVAL) begin
                            pub  <= 1'b1;
                            pctr <= 5'd0;
                            scnt <= 16'd0;
                        end
                    end else begin
                        bctr <= bctr + 5'd1;
                    end
                end
            endcase
        end
    end

endmodule
