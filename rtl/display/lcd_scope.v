//============================================================================
//  lcd_scope.v -- 480x272 performance display for the 8-key instrument
//
//  Layout
//
//      y   0.. 27   x   0..479   8 white-key cells, 60 px each (lit = pressed)
//      y  28..163   x   0..479   waveform scope, 480 samples of history
//      y 164..231   x   0..479   ADSR envelope curve, 480 points of history
//      y 232..239   x   0..191   status strip (4 octave + 4 timbre blocks)
//      y 240..271   x   0..479   8 per-voice envelope bars, 60 px each
//
//  Two 512x16 history RAMs (one BSRAM each):
//      wave_buf   written every audio sample      -> 480 samples =  9.96 ms
//      env_buf    written every 32nd audio sample -> 480 points  = 318.5 ms
//
//  The envelope time base is deliberately 32x slower than the audio one: an
//  ADSR attack is ~4 ms but the decay/release are ~250 ms each, so a 10 ms
//  window would only ever show the attack ramp.  318 ms shows the whole shape.
//
//  No frame buffer and no line-drawing hardware: every pixel is decided from
//  its own (x,y) plus two samples read from each RAM (current column and the
//  previous one), which is enough to draw a continuous trace.
//
//  Pipeline (12 clk per pixel, same discipline as lcd_panel.v -- a single
//  cycle decode cost a 12-level path and dropped Fmax to 61.6 MHz):
//
//      ph  0 : issue read addresses A0 for both RAMs
//      ph  2 : capture current samples, issue A0-1
//      ph  4 : capture previous samples
//      ph  5 : register sample -> screen-row geometry, x/y, key, bar level
//      ph  7 : register segment endpoints
//      ph  8 : register hit flags
//      ph  9 : register colour
//      ph 10 : final register together with de / hs / vs (pix_tick)
//============================================================================
`timescale 1ns / 1ps

module lcd_scope #(
    parameter integer H_ACT  = 480,
    parameter integer V_ACT  = 272,
    parameter integer VOICES = 8,
    //  Pixels are produced every DIV sys clocks.  Production uses 12
    //  (108 MHz / 12 = 9 MHz).  The testbench lowers it to run faster.
    parameter integer DIV    = 12
)(
    input  wire         clk,
    input  wire         rst_n,

    // waveform history (one write per audio sample)
    input  wire         wr_en_w,
    input  wire [8:0]   wr_addr_w,
    input  wire [15:0]  wr_data_w,

    // waveform trigger: address of the most recent rising zero crossing.
    // Without it a steady tone scrolls across the screen (free-running
    // scope); with it the picture stands still.
    input  wire [8:0]   trig_addr,
    input  wire         trig_ok,

    // envelope history (one write every 32nd audio sample)
    input  wire         wr_en_e,
    input  wire [8:0]   wr_addr_e,
    input  wire [15:0]  wr_data_e,

    // live state
    input  wire                 latch_mode_w,   // 1 = latch (hold) mode is on
    input  wire [VOICES-1:0]    key_gate,
    input  wire [16*VOICES-1:0] env_flat,
    input  wire [1:0]           oct,
    input  wire [1:0]           timbre,
    input  wire [3:0]           vol,            // audio_out gain index, for the status strip
    input  wire                 test_en,        // 1 = on-site self test is active
    input  wire                 wave_mode,      // 1 = 4-wavetable additive mode
    input  wire [2:0]           fx,             // expression bank: b0 vib, b1 echo, b2 glide
    input  wire [1:0]           dmode,          // 0 = waveform, 1 = spectrum, 2 = Lissajous
    input  wire [15:0]          liss_span,      // per-column {ymax[7:0], ymin[7:0]} of the X-Y figure
    input  wire [63:0]          spec_flat,      // 16 spectrum levels, 4 bits each
    input  wire [5:0]           vib_abs,        // |vibrato detune|, 0 when off
                                                //   -- also keeps the LFO out of the
                                                //   optimiser's sweep list: an unused
                                                //   output made Gowin delete u_lfo

    // panel
    //
    //  Timing taps for the Lissajous renderer.  The row/column counters live in
    //  here (lcd_timing is instantiated below), so the renderer has to be handed
    //  the column index and the blanking flag from inside.  The path is
    //  x -> liss_render address -> BSRAM -> registered data -> liss_span, so
    //  there is no combinational loop back into this module.
    //
    output wire [9:0]   tmg_x,          // current display column
    output wire         tmg_vblank,     // high during vertical blanking
    output wire         lcd_dclk,
    output reg          lcd_hs,
    output reg          lcd_vs,
    output reg          lcd_de,
    output reg  [4:0]   lcd_r,
    output reg  [5:0]   lcd_g,
    output reg  [4:0]   lcd_b
);
    localparam integer WAVE_Y0 = 28;
    localparam integer WAVE_Y1 = 164;
    localparam integer ENV_Y0  = 164;
    localparam integer ENV_Y1  = 232;
    localparam integer STAT_Y0 = 232;
    localparam integer STAT_Y1 = 240;
    localparam integer BARS_Y0 = 240;

    //  NOTE: 'integer' is signed, so the expressions below that mix these
    //  constants with $signed samples stay signed.  Do NOT use
    //  "localparam signed [15:0]" -- iverilog rejects it.  Also note that
    //  "cell" is a reserved Verilog keyword, hence kcell.
    localparam [15:0] WAVE_BASE = 16'd95;   // used as $signed(...) so the subtraction stays signed
    localparam [15:0] ENV_BASE  = 16'd231;

    //------------------------------------------------------------------
    // timing
    //------------------------------------------------------------------
    wire [3:0] ph;
    wire       pix_tick;
    wire [9:0] x;
    wire [9:0] y;

    lcd_timing #(.DIV(DIV), .H_ACT(H_ACT), .V_ACT(V_ACT)) u_tmg (
        .clk     (clk),
        .rst_n   (rst_n),
        .ph      (ph),
        .pix_tick(pix_tick),
        .x       (x),
        .y       (y)
    );

    assign tmg_x      = x;
    assign tmg_vblank = (y >= V_ACT);

    //------------------------------------------------------------------
    // column -> 60 px key cell index, x/60 by reciprocal.
    // 65536/60 = 1092.27, so the plain reciprocal 1093 puts every boundary
    // one pixel to the right (x = 60 lands in cell 1, not cell 0) and the
    // first cell of each row lights up twice.  1085 rounds down instead:
    // x = 59 -> 0, x = 60 -> 1, x = 119 -> 1, x = 120 -> 2, ... with a
    // worst-case error of one pixel at x = 479, which no one can see.  The
    // multiply is 20 bits wide, so the quotient reaches 8 for x >= 480 (i.e.
    // inside the horizontal blanking); clamp it, otherwise
    // env_flat[kcell*16 +: 16] reads past the end of the vector and drags X
    // into the bar heights right at the frame boundary.
    //------------------------------------------------------------------
    wire [19:0] m_cell = {10'b0, x} * 20'd1093;
    wire [3:0]  kcell  = (m_cell[19:16] > 4'd7) ? 4'd7 : m_cell[19:16];

    //------------------------------------------------------------------
    // history RAMs
    //------------------------------------------------------------------
    reg  [8:0]  base_w, base_e;
    reg  [8:0]  ra_w, ra_e;
    wire [15:0] rd_w, rd_e;
    reg  [15:0] dc_w, dc_e;      // current column
    reg  [15:0] dp_w, dp_e;      // previous column
    reg  [1:0]  sw;              // sample-fetch step: 0/1/2

    // Both sums wrap inside the 512-entry buffer: base_* is (write pointer -
    // 480) modulo 512, so base + x is only a valid address while x < 480.  A
    // 9 bit sum gives that for free; a 10 bit one grows past the RAM and the
    // extra bit makes the read return whatever was in the unwritten region.
    wire [8:0] iw0 = base_w + x[8:0];
    wire [8:0] ie0 = base_e + x[8:0];

    // Window start for the frame that is about to be scanned.  The trigger
    // address is the newest rising zero crossing, so the window ENDS there:
    // wstart = trig_addr - 479.  Putting the crossing at the START (the usual
    // X-Y scope look) is impossible here -- a tone's newest crossing is always
    // within one period of "now", so start-triggering would need samples that
    // have not been written yet and the right half of the screen would show
    // stale data from the previous sweep (that is exactly what made the trace
    // scroll by 6 rows per frame).  Ending the window on the crossing keeps
    // every column inside already-written history.
    wire [8:0] wstart = trig_ok ? trig_addr : (wr_addr_w - 9'd480);

    // The envelope buffer is written once every ENV_DEC samples, so right after
    // reset it only holds a handful of points.  A fixed "now - 480" window
    // would leave most columns reading unwritten (zero) RAM, which drew a tiny
    // stub of curve in the left corner.  Until the buffer holds a full window,
    // anchor at 0 and let the newest point walk rightwards off the screen.
    wire [8:0] estart = (wr_addr_e >= 9'd480) ? (wr_addr_e - 9'd480) : 9'd0;

    // Column address latched at the start of the pixel.  x advances on the
    // same edge that pix_start is seen, so reading the live iw0 a couple of
    // clocks into the fetch returns the NEXT column's address -- with a short
    // DIV (the testbench uses 3) both samples then come from the same place.
    reg [8:0] cw_q, ce_q;

    // The waveform buffer is stereo in the top level (the Lissajous page needs
    // L and R of the same instant) but the scope itself only ever plots the
    // mono mix, so the right channel is left open here.  The envelope buffer is
    // genuinely mono -- its upper plane is tied off.
    wire [15:0] rd_w_r_unused;

    wave_buf u_buf_w (
        .clk       (clk),
        .wr_en     (wr_en_w),
        .wr_addr   (wr_addr_w),
        .wr_data_l (wr_data_w),
        .wr_data_r (wr_data_w),
        .rd_addr   (ra_w),
        .rd_data_l (rd_w),
        .rd_data_r (rd_w_r_unused)
    );

    wave_buf u_buf_e (
        .clk       (clk),
        .wr_en     (wr_en_e),
        .wr_addr   (wr_addr_e),
        .wr_data_l (wr_data_e),
        .wr_data_r (16'd0),
        .rd_addr   (ra_e),
        .rd_data_l (rd_e),
        .rd_data_r ()
    );

    //------------------------------------------------------------------
    // pipeline stage 1 (ph 5): geometry of the sample being drawn
    //------------------------------------------------------------------
    reg signed [15:0] yc_q,  ycp_q;     // waveform rows (current / previous)
    reg signed [15:0] ye_q,  yep_q;     // envelope rows
    reg signed [15:0] btop_q;           // per-voice bar top row
    reg        [3:0]  lev_q;
    reg               key_q;
    reg               mode_q;
    reg               tst_q;            // test_en, pipelined with the geometry
    reg               wm_q;             // wave_mode, same pipeline stage
    reg        [2:0]  fx_q;             // fx_mode, same pipeline stage
    reg  [1:0]        dm_q;             // display page, same pipeline stage
    reg  [15:0]       lyi_q;            // Lissajous span, pipelined with the geometry
    reg               lok_q;            // 1 = this column carries samples
    reg        [5:0]  vab_q;            // |vibrato| in the same pipeline stage
    reg        [3:0]  slvl_q;           // spectrum level of this 30 px column
    reg        [9:0]  stop_q;           // top row of that bar
    reg        [9:0]  x_q, y_q;
    reg        [1:0]  oct_q, tim_q;
    reg        [3:0]  vol_q4;

    wire signed [15:0] s_cur  = dc_w;
    wire signed [15:0] s_prev = dp_w;
    // env_live is captured in stage 1 together with the geometry, so it has to
    // be indexed by the column the PIPELINE is on (x_q), not by the live x --
    // x has already run several pixels ahead by then and the bar heights were
    // being taken from a neighbouring voice, which is what made two bar cells
    // light up for a single note.
    wire [19:0] m_cell_q = {10'b0, x_q} * 20'd1093;
    wire [3:0]  kcell_q  = (m_cell_q[19:16] > 4'd7) ? 4'd7 : m_cell_q[19:16];
    wire        [15:0] env_live = env_flat[kcell_q*16 +: 16];

    //------------------------------------------------------------------
    // pipeline stage 2 (ph 7): segment endpoints
    //------------------------------------------------------------------
    reg signed [15:0] wlo_q, whi_q;
    reg signed [15:0] elo_q, ehi_q;

    wire signed [15:0] wlo = (yc_q  < ycp_q) ? yc_q  : ycp_q;
    wire signed [15:0] whi = (yc_q  < ycp_q) ? ycp_q : yc_q;
    wire signed [15:0] elo = (ye_q  < yep_q) ? ye_q  : yep_q;
    wire signed [15:0] ehi = (ye_q  < yep_q) ? yep_q : ye_q;

    //------------------------------------------------------------------
    // pipeline stage 3 (ph 8): hit flags
    //------------------------------------------------------------------
    reg w_hit, e_hit, e_fill, bar_hit, bar_cap;
    reg  [4:0]  sbk_q;      // status-strip block index, registered
    reg         ioct_q, itim_q, ivol_q, itst_q, iwav_q, ifx_q, idm_q;

    reg l_hit;                        // Lissajous page hit (see stage 3)

    //------------------------------------------------------------------
    // Pipeline control.
    //
    // The datapath advances on EVERY clock instead of on selected phase
    // numbers, so it is completely independent of DIV: whatever the pixel
    // period is, each stage sits one clock behind the previous one and the
    // colour is ready before the pixel leaves.  Sampling on "ph == k" broke
    // as soon as DIV got small (the testbench uses DIV = 3), because several
    // stages then mapped onto the same phase and the else-if chain silently
    // skipped whole stages.
    //
    // With DIV = 12 this is the original 0/2/4/5/7/8/9/10 schedule, just
    // shifted: the panel pins are driven straight, so nothing is lost in the
    // long blanking stretches between pixels.
    //------------------------------------------------------------------
    wire pix_start = (ph == 4'd0);          // the position counters advance here
    wire out_ph    = (ph == 4'd0);          // panel pins are latched here
    wire pipe_en   = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            base_w <= 9'd0;  base_e <= 9'd0;
            ra_w   <= 9'd0;  ra_e   <= 9'd0;
            dc_w   <= 16'd0; dc_e   <= 16'd0;
            dp_w   <= 16'd0; dp_e   <= 16'd0;
            sw     <= 2'd0;
            cw_q   <= 9'd0;
            ce_q   <= 9'd0;
            yc_q   <= 16'sd0;  ycp_q <= 16'sd0;
            ye_q   <= 16'sd0;  yep_q <= 16'sd0;
            btop_q <= 16'sd272;
            lev_q  <= 4'd0;    key_q <= 1'b0;
            mode_q <= 1'b0;
            tst_q  <= 1'b0;
            wm_q   <= 1'b0;
            fx_q   <= 3'd0;
            x_q    <= 10'd0;   y_q   <= 10'd0;
            oct_q  <= 2'd0;    tim_q <= 2'd0;
            wlo_q  <= 16'sd0;  whi_q <= 16'sd0;
            elo_q  <= 16'sd0;  ehi_q <= 16'sd0;
            w_hit  <= 1'b0;    e_hit <= 1'b0;
            e_fill <= 1'b0;    bar_hit <= 1'b0; bar_cap <= 1'b0;
            l_hit  <= 1'b0;
            lyi_q  <= 16'd0;   lok_q <= 1'b0;
            sbk_q  <= 5'd0;
            ioct_q <= 1'b0;    itim_q <= 1'b0;
            ivol_q <= 1'b0;    itst_q <= 1'b0;
            iwav_q <= 1'b0;    ifx_q  <= 1'b0;
            idm_q  <= 1'b0;
        end else if (pipe_en) begin
            //----------------------------------------------------------
            // sample fetch
            //
            // wave_buf has ONE register of read latency.  Asking for address
            // A on this edge means that A's data appears on rd_w on the next
            // edge.  The trace needs two neighbouring samples per column, so
            // the fetch is a fixed two-step sequence keyed by `sw`:
            //
            //     sw = 0 : the pixel starts; issue iw0-1
            //     sw = 1 : rd_w now holds mem[iw0-1] -> prev; issue iw0
            //     sw = 2 : rd_w now holds mem[iw0]   -> cur;  step back to 0
            //
            // The address is held in a separate register (ra_w is the one the
            // RAM sees), so nothing depends on how many clocks a pixel lasts.
            // The earlier version compared ra_w against the live iw0 instead,
            // which only matched when the counter happened not to have moved
            // yet -- so both captures ended up reading the same address and
            // s_cur == s_prev made the trace a flat line.
            //----------------------------------------------------------
            //----------------------------------------------------------
            // Window origin.
            //
            // THE SCROLLING BUG: this used to re-latch base_w on x == 0 of
            // EVERY ROW, taking its value from the live trigger.  The trigger
            // address moves several times per LCD frame (the zero-crossing
            // queue rotates once per tone period), so each of the 272 lines
            // started at a different phase and the whole picture sheared
            // downwards -- which looks exactly like a free-running scope that
            // never stops.  The origin is now latched ONCE per frame, on the
            // first pixel of y == 0, and every line of that frame re-uses it.
            // Between frames the origin can still jump, but a jump of a whole
            // number of periods is invisible on a periodic signal.
            //----------------------------------------------------------
            if (pix_start) begin
                if (x == 10'd0 && y == 10'd0) begin
                    base_w <= wstart;              // one snapshot per frame
                    base_e <= estart;
                    cw_q   <= wstart;
                    ce_q   <= estart;
                end else if (x == 10'd0 && y < V_ACT) begin
                    cw_q   <= base_w;              // frozen origin
                    ce_q   <= base_e;
                end else begin
                    cw_q   <= iw0;
                    ce_q   <= ie0;
                end
            end

            case (sw)
                2'd0: begin
                    ra_w <= cw_q - 9'd1;
                    ra_e <= ce_q - 9'd1;
                    if (pix_start) sw <= 2'd1;
                end
                2'd1: begin
                    dp_w <= rd_w;
                    dp_e <= rd_e;
                    ra_w <= cw_q;
                    ra_e <= ce_q;
                    sw   <= 2'd2;
                end
                default: begin
                    dc_w <= rd_w;
                    dc_e <= rd_e;
                    sw   <= 2'd0;
                end
            endcase

            //----------------------------------------------------------
            // stage 1: geometry of the sample being drawn
            //
            // x_q / y_q are NOT latched here.  The colour stage reads them
            // five clocks later, so they have to track the pixel whose colour
            // is being produced -- they are latched next to the colour
            // registers instead (see "position pipeline" below).  Latching
            // them here made every pixel carry the coordinates of the pixel
            // from five clocks ago, which showed up as a one-pixel shift on
            // every region boundary and as the first 4 rows of the key strip
            // losing their colour.
            //----------------------------------------------------------
            yc_q   <= $signed(WAVE_BASE) - (s_cur  >>> 5);    // +-1024 rows: one voice (mix_out ~+-2045) fills ~94% of the 136-row box; 2+ voices saturate it, which reads as clipping
            ycp_q  <= $signed(WAVE_BASE) - (s_prev >>> 5);
            ye_q   <= $signed(ENV_BASE)  - {10'b0, dc_e[15:10]};   // 0..63 rows
            yep_q  <= $signed(ENV_BASE)  - {10'b0, dp_e[15:10]};
            btop_q <= 16'sd272 - {11'b0, env_live[15:11]};
            lev_q  <= env_live[15:12];
            key_q  <= key_gate[kcell[2:0]];
            mode_q <= latch_mode_w;
            tst_q  <= test_en;
                wm_q   <= wave_mode;
            fx_q   <= fx;
            dm_q   <= dmode;
            lyi_q  <= liss_span;
            lok_q  <= (liss_span[7:0] <= liss_span[15:8]);
        vab_q  <= vib_abs;
            oct_q  <= oct;
            tim_q  <= timbre;
            vol_q4 <= vol;

            //----------------------------------------------------------
            // stage 2: segment endpoints
            //----------------------------------------------------------
            wlo_q <= wlo;
            whi_q <= whi;
            elo_q <= elo;
            ehi_q <= ehi;

            //----------------------------------------------------------
            // stage 3: hit flags
            //----------------------------------------------------------
            // a zero-extended y_q compared against a negative signed row
            // turns into a huge unsigned value, so off-screen traces are
            // rejected without a separate guard
            w_hit   <= (y_q >= WAVE_Y0) && (y_q < WAVE_Y1) &&
                       ({6'b0, y_q} >= wlo_q) && ({6'b0, y_q} <= whi_q);
            e_hit   <= (y_q >= ENV_Y0) && (y_q < ENV_Y1) &&
                       ({6'b0, y_q} >= elo_q) && ({6'b0, y_q} <= ehi_q);
            // strictly below the curve: with env = 0 the curve sits on the
            // baseline (ye_q == ENV_BASE), and ">=" would paint that whole
            // row as area fill even though nothing is sounding
            e_fill  <= (y_q >= ENV_Y0) && (y_q < ENV_Y1) &&
                       (y_q > ye_q);
            // Lissajous page: the column index comes from the LEFT sample, so the
            // span table (built in vblank by liss_render) is indexed by x_q and
            // simply compared against y_q here.
            l_hit   <= (dm_q == 2'd2) && lok_q &&
                       (y_q >= 10'd28) && (y_q < 10'd164) &&
                       ({6'b0, y_q} >= ({6'b0, lyi_q[7:0]}  + 16'd28)) &&
                       ({6'b0, y_q} <= ({6'b0, lyi_q[15:8]} + 16'd28));
            bar_hit <= (y_q >= BARS_Y0) && ({6'b0, y_q} >= btop_q);
            bar_cap <= (y_q >= BARS_Y0) && ({6'b0, y_q} >= btop_q) &&
                       ({6'b0, y_q} <= btop_q + 16'sd2);

            //----------------------------------------------------------
            // position pipeline: keep x_q / y_q in step with the colour
            //----------------------------------------------------------
            x_q <= x;
            y_q <= y;
            slvl_q <= slvl_x;
            stop_q <= stop_x;
            //  Status-strip decode, registered here so stage 4 only has to AND
            //  flip-flop outputs together.  Left combinational it was the
            //  worst setup path in the design (x_q -> 22-bit multiply ->
            //  compares -> nibble select, 0.013 ns of slack).
            sbk_q  <= sblk_x;
            ioct_q <= (x <  10'd48);
            itim_q <= (x >= 10'd48)  && (x < 10'd96);
            ivol_q <= (x >= 10'd96)  && (x < 10'd156);
            itst_q <= (x >= 10'd168) && (x < 10'd192);
            iwav_q <= (x >= 10'd192) && (x < 10'd216);
            ifx_q  <= (x >= 10'd216) && (x < 10'd312);
            idm_q  <= (x >= 10'd320) && (x < 10'd368);
        end
    end

    //------------------------------------------------------------------
    // stage 4: colour
    //------------------------------------------------------------------
    reg [4:0] nr;
    reg [5:0] ng;
    reg [4:0] nb;

    // Status strip layout (y STAT_Y0..STAT_Y1), 12 px blocks by reciprocal
    // (x*2731 >> 15 == x/12).  The product is widened to 22 bits because
    // 1023*2731 needs 22 bits; the old 20-bit version wrapped at x >= 384.
    //     x   0..47   octave  ladder, 4 blocks   (1 per octave 0..2)
    //     x  48..95   timbre  ladder, 4 blocks   (1 per timbre 0..3)
    //     x  96..155  volume  ladder, 5 blocks   (1 per gain step 6..10)
    //     x 168..191  TEST flag   (on-site self test running)
    //     x 192..215  WAVE flag   (4-wavetable mode running)
    //
    //  NOTE the ladders are explicitly gated to x < 156.  The old code used
    //  sblk >= 14 for the TEST flag and let the ladder comparisons run all the
    //  way to x = 479; because a 20-bit product overflows at x >= 384 the
    //  block index wrapped back to 0 and the octave/timbre ladder lit up a
    //  second time on the right half of the strip.  Explicit windows remove
    //  both the wrap and the accidental 216 px wide "TEST" band.
    //  Computed from x (the timing generator's own register) and registered
    //  into sbk_q by stage 3; stage 4 consumes only flip-flop outputs.
    wire [21:0] m_stat = {12'b0, x} * 22'd2731;
    wire [4:0]  sblk_x = m_stat[19:15];

    wire        oct_on = ioct_q && (sbk_q <= {3'b0, oct_q});
    wire        tim_on = itim_q && ((sbk_q - 5'd4) <= {3'b0, tim_q});

    // volume ladder: 5 blocks, x 96..155, one per gain step 6..10
    wire [3:0]  vol_lvl = (vol_q4 < 4'd6) ? 4'd0 : (vol_q4 - 4'd6);
    wire        vol_on  = ivol_q && ((sbk_q - 5'd8) <= {1'b0, vol_lvl});

    wire        tst_on  = tst_q && itst_q;   // TEST flag: solid red
    wire        wav_on  = wm_q  && iwav_q;   // WAVE flag: solid orange

    // expression/effect bank: 8 blocks, x 216..311, one per fx_mode value.
    // Block 0 is always lit while fx_mode != 0 is NOT required -- the ladder
    // shows fx_mode+1 blocks so that "off" still draws a single dim block and
    // the player can tell the strip is alive.
    wire        fx_on   = ifx_q && ((sbk_q - 5'd18) <= {2'b0, fx_q});
    //  display page ladder: 4 blocks at x 320..367, (dmode+1) of them lit, so
    //  page 0 (waveform) always shows one dim block and the strip looks alive.
    wire        dm_on   = idm_q && ((sbk_q - 5'd26) <= {3'b0, dm_q});

    //------------------------------------------------------------------
    // spectrum bars (dmode == 1) -- the wave box becomes 16 bars, 30 px each
    //
    // x/30 by reciprocal: 65536/30 = 2184.5, so 2185.  The product stays
    // inside 20 bits (479 * 2185 = 1.05e6 < 2^20) and the quotient is 0..15,
    // exactly the bar index.
    //
    // Each bar grows UP from y = 163, 8 rows per level, so level 15 reaches
    // y = 44 and level 0 draws nothing at all.
    //------------------------------------------------------------------
    //  TIMING.  The bar level used to be derived inside the colour stage:
    //    DSP multiply -> 16:1 mux over spec_flat -> subtract -> compare -> pixel
    //  which measured -0.30 ns of slack.  The level only changes every 30
    //  pixels, so it is decoded one pipeline stage earlier (from the raw x,
    //  in step with x_q) and the colour stage now compares two registers.
    wire [19:0] m_bar_x = {10'b0, x} * 20'd2185;
    wire [3:0]  sbar_x  = m_bar_x[19:16];
    wire [3:0]  slvl_x  = spec_flat[sbar_x*4 +: 4];
    wire [9:0]  stop_x  = 10'd164 - {1'b0, slvl_x, 3'b000};   // 164 - slvl*8

    wire [3:0]  slvl  = slvl_q;
    wire [9:0]  stop  = stop_q;
    wire        sp_on = (dm_q == 2'd1) && (y_q >= 10'd28) && (y_q < 10'd164) &&
                        (y_q >= stop);
    wire        sp_cap = sp_on && (y_q < stop + 10'd2);

    always @(posedge clk) begin
        if (!rst_n) begin
            nr <= 5'd1;  ng <= 6'd4;  nb <= 5'd9;
        end else begin
            nr <= 5'd1;  ng <= 6'd4;  nb <= 5'd9;          // background

            if (y_q < 10'd28) begin
                if (key_q) begin
                    nr <= 5'd31;  ng <= 6'd44;  nb <= 5'd0;   // pressed: amber
                end else if (y_q == 10'd27) begin
                    nr <= 5'd2;   ng <= 6'd6;   nb <= 5'd14;  // base line
                end else begin
                    nr <= 5'd3;   ng <= 6'd6;   nb <= 5'd12;  // idle
                end
            end else if (y_q < WAVE_Y1) begin
                if (dm_q == 2'd1) begin
                    // spectrum page: 16 live bars instead of the trace
                    if (sp_on) begin
                        if (sp_cap) begin
                            nr <= 5'd31;  ng <= 6'd52;  nb <= 5'd10;  // bar head
                        end else begin
                            nr <= 5'd2;   ng <= 6'd30;  nb <= 5'd20;  // bar body
                        end
                    end else if (y_q == 10'd163) begin
                        nr <= 5'd2;   ng <= 6'd16;  nb <= 5'd26;      // base line
                    end
                end else if (dm_q == 2'd2) begin
                    // Lissajous page: filled X-Y figure, warm violet so it is
                    // distinguishable from the spectrum bars and the waveform
                    if (l_hit) begin
                        nr <= 5'd22;  ng <= 6'd26;  nb <= 5'd31;
                    end else if ((y_q == 10'd96) || (x_q == 10'd240)) begin
                        nr <= 5'd2;   ng <= 6'd14;  nb <= 5'd22;  // centre cross
                    end
                end else if (w_hit) begin
                    nr <= 5'd5;   ng <= 6'd58;  nb <= 5'd14;  // trace: green
                end else if (y_q == 10'd95) begin
                    nr <= 5'd2;   ng <= 6'd16;  nb <= 5'd26;  // zero line
                end
            end else if (y_q < ENV_Y1) begin
                if (e_hit) begin
                    nr <= 5'd3;   ng <= 6'd50;  nb <= 5'd30;  // curve: cyan (must fit 5 bits!)
                end else if (e_fill) begin
                    nr <= 5'd1;   ng <= 6'd16;  nb <= 5'd28;  // area fill
                end
            end else if (y_q < STAT_Y1) begin
                if (oct_on) begin
                    nr <= 5'd4;   ng <= 6'd40;  nb <= 5'd20;  // octave blocks
                end else if (tim_on) begin
                    case (tim_q)                              // timbre swatch
                        2'd0: begin nr <= 5'd4;  ng <= 6'd56; nb <= 5'd4;  end
                        2'd1: begin nr <= 5'd31; ng <= 6'd56; nb <= 5'd4;  end
                        2'd2: begin nr <= 5'd31; ng <= 6'd22; nb <= 5'd4;  end
                        default: begin nr <= 5'd20; ng <= 6'd6; nb <= 5'd31; end
                    endcase
                end else if (vol_on) begin
                    // volume ladder lights up left to right as gain rises
                    nr <= 5'd31; ng <= 6'd40; nb <= 5'd2;
                end else if (tst_on) begin
                    // TEST flag: solid red, unmistakable at a glance
                    nr <= 5'd31; ng <= 6'd0;  nb <= 5'd0;
                end else if (wav_on) begin
                    // WAVE flag: solid orange = 4-wavetable additive mode
                    nr <= 5'd31; ng <= 6'd24; nb <= 5'd0;
                end else if (fx_on) begin
                    // expression bank ladder: cyan, one block per fx_mode step.
                    // The green channel rides the LFO amplitude, so when FX=1 (vibrato)
                    // the ladder breathes at 5 Hz -- a live expression indicator.
                    nr <= 5'd2;  ng <= 6'd20 + {1'b0, vab_q[4:0]}; nb <= 5'd31;
                end else if (dm_on) begin
                    // display page ladder: soft violet
                    nr <= 5'd18; ng <= 6'd8;  nb <= 5'd31;
                end
            end else begin
                if (bar_hit) begin
                    if (bar_cap) begin
                        nr <= 5'd31;  ng <= 6'd52;  nb <= 5'd31;  // bar head
                    end else begin
                        nr <= 5'd18;  ng <= 6'd14;  nb <= 5'd26;  // bar body (must fit 5 bits!)
                    end
                end
            end

            // latch-mode marker: a small magenta patch in the top-right
            // corner (16 x 18 px).  Later assignment wins, so it simply
            // overwrites whatever that corner held.
            if (mode_q && (x_q > 10'd463) && (y_q < 10'd18)) begin
                nr <= 5'd31;  ng <= 6'd8;  nb <= 5'd31;
            end
        end
    end

    //------------------------------------------------------------------
    // panel output
    //------------------------------------------------------------------
    // The colour reaching the pins on a given cycle describes x_q / y_q, NOT
    // x / y: the pipeline started several clocks ago and the position counters
    // have already moved on.  Driving de / hs / vs from x / y would put an
    // offset on the timing signals relative to the data.
    wire hsync_n = ~((x_q >= H_ACT + 2) && (x_q < H_ACT + 43));
    wire vsync_n = ~((y_q >= V_ACT + 2) && (y_q < V_ACT + 12));

    // nr / ng / nb are registered on the same edge as x_q / y_q, so the pins
    // must NOT sample them on that edge -- doing so sends the previous pixel's
    // colour out and shifts the whole picture one pixel to the right (the very
    // first pixel of every row then keeps the background colour).  Sample them
    // one clock later, unconditionally, and pass the timing signals through
    // the same number of registers so all six stay pixel-locked.
    reg        [4:0] or_;
    reg        [5:0] og;
    reg        [4:0] ob;
    reg              o_de, o_hs, o_vs;

    always @(posedge clk) begin
        if (!rst_n) begin
            or_  <= 5'd0;
            og   <= 6'd0;
            ob   <= 5'd0;
            o_de <= 1'b0;
            o_hs <= 1'b1;
            o_vs <= 1'b1;
        end else begin
            or_  <= nr;
            og   <= ng;
            ob   <= nb;
            o_de <= (x_q < H_ACT) && (y_q < V_ACT);
            o_hs <= hsync_n;
            o_vs <= vsync_n;
        end
    end

    // px_q / py_q describe the pixel whose colour is on the wires RIGHT NOW.
    // lcd_r/g/b sit two registers after the colour stage (nr -> or_ -> lcd_r),
    // so the coordinates need the same two registers or the testbench walks
    // the active area one pixel ahead of the colour it is looking at.
    reg [9:0] px1_q, py1_q;
    reg [9:0] px_q,  py_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            px1_q <= 10'd0;
            py1_q <= 10'd0;
        end else if (out_ph) begin
            px1_q <= x_q;
            py1_q <= y_q;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            lcd_r  <= 5'd0;
            lcd_g  <= 6'd0;
            lcd_b  <= 5'd0;
            lcd_de <= 1'b0;
            lcd_hs <= 1'b1;
            lcd_vs <= 1'b1;
            px_q   <= 10'd0;
            py_q   <= 10'd0;
        end else if (out_ph) begin
            lcd_r  <= or_;
            lcd_g  <= og;
            lcd_b  <= ob;
            lcd_de <= o_de;
            lcd_hs <= o_hs;
            lcd_vs <= o_vs;
            px_q   <= px1_q;
            py_q   <= py1_q;
        end
    end

    // pixel clock, high for the first half of the pixel period.
    //  DIV = 12 -> high for ph 0..5, i.e. 9 MHz at 50 % duty.
    //  Writing the literal 6 here breaks any DIV below 6: with DIV = 3 the
    //  expression is always true, DCLK never falls, and the colour stage --
    //  which is clocked on pix_tick -- still runs, but the panel side looks
    //  dead.  Keep it derived from DIV.
    assign lcd_dclk = (ph < DIV / 2);

endmodule
