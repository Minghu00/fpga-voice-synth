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
//  ROTATING ACCUMULATOR ARRAY  (timing fix)
//  ----------------------------------------
//  The first version kept the 16 accumulators as ordinary arrays addressed by
//  the bin counter:
//
//      re[bctr] <= re[bctr] + pS;          // 16:1 read mux + 32-bit add
//      are_q <= |re[pctr]|;                // 16:1 read mux + negate
//      lvl_flat[pctr*4 +: 4] <= lvl;       // 4-bit variable write, 16:1 decode
//
//  Synthesised as register arrays, every one of those accesses becomes a wide
//  multiplexer fed by sixteen scattered flip-flop banks.  The 16:1 32-bit read
//  mux alone measured about 9 ns of routing, and three paths came out within
//  0.05 ns of the 9.26 ns clock period (Fmax 108.0 MHz with +0.013 ns slack).
//
//  The bins are always visited in order 0,1,2,..15 and then again 0,1,..15
//  when publishing, so the array can simply ROTATE underneath the sweep: the
//  bin being worked on is always slot 0, and after 16 steps everything is back
//  where it started.
//
//      re_new = re[0] + pS;                    // read slot 0, no mux
//      re[i] <= re[i+1] for i<15;              // pure neighbour wiring
//      re[15] <= re_new;                       // fixed write slot, no decode
//
//  Publishing rotates the same way and shifts zeros in, which doubles as the
//  accumulator clear at the end of a block -- the 4-bit variable write into
//  lvl_flat[] is gone too, replaced by a shift register.
//
//  BIN MAP
//  -------
//  N = 512 at fs = 48214.2857 Hz  ->  94.174 Hz per bin.
//  Bin numbers k run 1..16 (k = 0 would be DC) so they cover 94 Hz .. 1.507 kHz,
//  which brackets the range the keys can play.  The pad layout of keymap8.v is
//  the C major arpeggio C4 E4 G4 C5 E5 G5 C6 E6, i.e. 261.6 Hz .. 1318.5 Hz;
//  E6 lands on bin 14, so the top note still has two spare bins to its right.
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
    // Registered; stable for a whole block (512 / 48214.2857 = 10.62 ms).
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
    // rotating per-bin state.  Slot 0 is ALWAYS the bin being worked on,
    // which is what removes every multiplexer from the accumulator path.
    //------------------------------------------------------------------
    reg  [8:0]        ph [0:NBINS-1];       // 0..N-1
    reg signed [31:0] re [0:NBINS-1];
    reg signed [31:0] im [0:NBINS-1];

    //  Rotation strobes (rot_sw_c / rot_pb_c below) are COMBINATIONAL off the
    //  sequencer state.  They used to be registered, which delayed the rotation
    //  by one clock -- and by then bctr had already advanced, so ph_nx added
    //  the NEXT bin's index and every bin accumulated its neighbour's k.

    //------------------------------------------------------------------
    // sequencer
    //------------------------------------------------------------------
    reg        pub;                         // 1 = publishing a finished block
    reg        run;                         // 1 = a sample is being swept
    reg  [2:0] step;                        // 0..4 inside one bin
    reg  [4:0] bctr;                        // bin slot while sweeping
    reg  [4:0] pctr;                        // bin slot while publishing
    reg        pphase;                      // 0 = find ref, 1 = write levels
    //  publish scratch: msb per bin and the block peak
    //  `msb_sh` is a SHIFT register (oldest bin at the top) instead of an
    //  array indexed by pctr -- see the header.  msb_d is the registered copy
    //  of the previous slot's msb so the `ref` compare only sees two flops.
    reg  [5*NBINS-1:0] msb_sh;              // 16 x 5, bin 0 at [79:75]
    reg  [4*NBINS-1:0] lvl_sh;              // 16 x 4, shifted out at the bottom
    reg  [4:0] ref;                         // msb of the loudest bin this block
    reg  [4:0] msb_d;                       // msb of the previous publish slot
    reg  [31:0] are_q, aim_q;               // |Re|, |Im| registered
    reg  [31:0] mag_q;                      // |Re|+|Im|, registered
    reg  [1:0]  pcnt;                       // 0 abs, 1 add, 2 encode
    reg         ptail;                      // one extra cycle to fold in slot LASTB
    //  msb_sh[5*NBINS-1 -: 5] is the oldest entry, i.e. the bin being published
    //  6 bits: `{1'b0, ref}` is 6 wide, and assigning that to a 5-bit net
    //  truncates (EX3791) whenever ref has bit 5 set.  Keep the width.
    wire [5:0] tt      = {1'b0, ref} - {1'b0, msb_sh[5*NBINS-1 -: 5]};  // 6 dB steps
    reg  [15:0] scnt;                       // samples in this block
    reg signed [15:0] xq;                   // sample being analysed
    reg signed [15:0] sv, cv;               // sin / cos of the current bin
    reg signed [31:0] pS, pC;               // the two products, pre-scaled

    wire [8:0] p_k   = ph[0];
    wire [8:0] p_cos = ph[0] + NQUART[8:0];
    wire [4:0] k1    = bctr + 5'd1;         // bin number k = slot + 1

    //  the value that rotates into slot LASTB on a sweep rotation
    wire signed [31:0] re_nx = re[0] + pS;
    wire signed [31:0] im_nx = im[0] - pC;
    wire        [8:0]  ph_nx = ph[0] + k1;

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
    //  Slot 0 only: the publish pass rotates the array instead of indexing it.
    wire signed [31:0] re_p = re[0];
    wire signed [31:0] im_p = im[0];
    wire        [31:0] a_re = re_p[31] ? (~re_p + 32'd1) : re_p;
    wire        [31:0] a_im = im_p[31] ? (~im_p + 32'd1) : im_p;
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
                              (tt  >= 6'd8)           ? 4'd0 :
                              (4'd15 - {tt[2:0], 1'b0});

    //  rotation strobes, both combinational off the sequencer state
    wire rot_sw_c = run && (step == 3'd4);
    wire rot_pb_c = pub && !pphase && !ptail && (pcnt == 2'd0);

    //  lvl_sh is 16 x 4; each level enters at the TOP and the previous ones
    //  slide down, so bin 0 ends up at [3:0] after sixteen steps, which is
    //  exactly lvl_flat[3:0].  (Shifting `{lvl, lvl_sh[63:4]}` -- NOT
    //  `{lvl, lvl_sh[59:0]}`, which throws away the entry just inserted.)
    wire [4*NBINS-1:0] lvl_nx = {lvl, lvl_sh[4*NBINS-1:4]};

    integer b;
    always @(posedge clk) begin
        //--------------------------------------------------------------
        // the rotation itself.  Pure neighbour wiring: each stage reads the
        // one above it and slot LASTB takes the freshly accumulated value.
        // Nothing else in this block writes re[]/im[]/ph[], so the order of
        // this and the sequencer below does not matter.
        //--------------------------------------------------------------
        if (rot_sw_c) begin
            for (b = 0; b < NBINS-1; b = b + 1) begin
                re[b] <= re[b+1];
                im[b] <= im[b+1];
                ph[b] <= ph[b+1];
            end
            re[NBINS-1] <= re_nx;
            im[NBINS-1] <= im_nx;
            ph[NBINS-1] <= ph_nx;
        end else if (rot_pb_c) begin
            for (b = 0; b < NBINS-1; b = b + 1) begin
                re[b] <= re[b+1];
                im[b] <= im[b+1];
            end
            re[NBINS-1] <= 32'sd0;
            im[NBINS-1] <= 32'sd0;
        end

        if (!rst_n) begin
            pub      <= 1'b0;
            run      <= 1'b0;
            step     <= 3'd0;
            bctr     <= 5'd0;
            pctr     <= 5'd0;
            pphase   <= 1'b0;
            ref      <= 5'd0;
            msb_d    <= 5'd0;
            msb_sh   <= {(5*NBINS){1'b0}};
            lvl_sh   <= {(4*NBINS){1'b0}};
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
            // publishing: two passes of 16 slots
            //   phase 0: record each bin's msb and find the block peak
            //   phase 1: turn (msb, ref) into the 4-bit bar level
            //----------------------------------------------------------
            if (!pphase) begin
                //  THREE CYCLES PER SLOT, and the accumulator array rotates
                //  (shifting zeros in) instead of being indexed by pctr.
                //  Cycle 0 registers |Re| and |Im| of slot 0 and rotates;
                //  cycle 1 does the 32-bit sum; cycle 2 runs the priority
                //  encoder on that register and shifts the msb into msb_sh.
                if (ptail) begin
                    // fold in slot LASTB, whose msb is still in msb_d
                    if (msb_d > ref) ref <= msb_d;
                    ptail  <= 1'b0;
                    pphase <= 1'b1;
                    pctr   <= 5'd0;
                end else if (pcnt == 2'd0) begin
                    // cycle 0: |Re| and |Im| of slot 0 (two conditional negates).
                    // The rotation itself is driven by rot_pb_c above.
                    are_q  <= a_re;
                    aim_q  <= a_im;
                    pcnt   <= 2'd1;
                end else if (pcnt == 2'd1) begin
                    // cycle 1: the 32-bit sum
                    mag_q <= are_q + aim_q;
                    pcnt  <= 2'd2;
                end else begin
                    // cycle 2: priority encoder on a register, shift-in
                    pcnt   <= 2'd0;
                    msb_sh <= {msb_sh[5*NBINS-6:0], msb_enc};
                    msb_d  <= msb_enc;
                    if (msb_d > ref) ref <= msb_d;
                    if (pctr == LASTB) ptail <= 1'b1;
                    else               pctr  <= pctr + 5'd1;
                end
            end else begin
                //  ONE CYCLE PER SLOT.  msb_sh[5*NBINS-1 -: 5] is the current
                //  bin's msb (oldest entry), so no multiplexer is involved.
                lvl_sh <= lvl_nx;
                msb_sh <= {msb_sh[5*NBINS-6:0], 5'd0};
                if (pctr == LASTB) begin
                    lvl_flat <= lvl_nx;
                    pub      <= 1'b0;
                    pphase   <= 1'b0;
                    ref      <= 5'd0;
                    pctr     <= 5'd0;
                    pcnt     <= 2'd0;
                    ptail    <= 1'b0;
                    lvl_sh   <= {(4*NBINS){1'b0}};
                    msb_sh   <= {(5*NBINS){1'b0}};
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
                default: begin              // accumulate, rotate (rot_sw_c), advance
                    step <= 3'd0;
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
