//=============================================================================
//  tb_inst.v  --  self-checking testbench for top_inst (8-key instrument)
//
//  Checks, in order
//    1. 9 MHz pixel clock (12 clk period, 6 clk half period)
//    2. HS period 525 pixels, VS period 286 lines
//    3. idle frame      : no key cell lit, no envelope bar, no envelope curve,
//                         waveform is a single flat line
//    4. one key down    : exactly one key cell lit, waveform trace spans many
//                         rows (i.e. a real sine is being played), envelope
//                         curve + area fill appear, one bar has height
//    5. two keys down   : exactly two key cells lit and two envelope bars
//                         (this is the simultaneous-press / polyphony check)
//    6. all released    : key cells go dark again
//
//  The waveform and envelope are read straight off the pixel stream, so this
//  exercises the whole chain: TTP229 -> keymap8 -> 32 oscillators -> ADSR ->
//  mixer -> history RAMs -> LCD pipeline.
//=============================================================================
`timescale 1ns / 1ps

module tb_inst;

    reg        clk27  = 1'b0;
    reg        rst_n  = 1'b0;
    reg  [3:0] dip    = 4'b0000;
    reg  [15:0] keys  = 16'h0000;
    reg        key_btn = 1'b1;   // Silicon Key_2: released = 1
    reg        vup_sw  = 1'b1;      // active-LOW: 1 = released
    wire       tp_scl, tp_sdo;
    wire       i2s_bclk, i2s_lrclk, i2s_din;
    wire       lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0] lcd_r;
    wire [5:0] lcd_g;
    wire [4:0] lcd_b;

    always #18.5185 clk27 = ~clk27;         // 27 MHz

    //  DIV = 3 keeps the 4-stage pixel pipeline (which needs ~11 sys clocks)
    //  fed while making one 272-line frame about 4x cheaper to simulate.
    //  The audio side is untouched: 2240 clocks per sample at 108 MHz.
    top_inst #(
        .INIT_CLK  (60),
        .POLL_CLK  (400),
        .SCL_HALF  (8),
        .ACTIVE_LOW(1),
        .ATT_STEP  (100),
        .DEC_STEP  (2),
        .REL_STEP  (4),
        .SUSTAIN   (16'd40000),
        .DIV       (3),
        // 4 audio samples instead of 38 000 so the long-press wavetable
        // toggle can be exercised inside a fast simulation
        .WHOLD     (4),
        .BTHR      (40),
        // A latch tap is "reported for TAP_HOLD samples".  The real value is
        // 965 samples (~20 ms), which is far longer than the 3 LCD frames
        // (~12.5 ms) these tests hold a pad for, so shrink it to the minimum
        // the rule allows.  The alternation immunity itself is covered by
        // sim/tb_latch.v at the production value.
        .TAP_HOLD  (8),
        // The waveform page is a single-shot snapshot: it waits SETTLE audio
        // samples after the set of pressed pads changes, then captures 480
        // samples.  Production waits 300 ms; these tests only run a handful of
        // LCD frames, so shrink it.  The freeze itself is covered by
        // sim/tb_scope_snap.v.
        .SETTLE    (40)
    ) dut (
        .clk27    (clk27),
        .rst_n    (rst_n),
        .tp_sdo   (tp_sdo),
        .dip      (dip),
        .sw5_vol  (1'b0),
        // vup_sw is an active-LOW board key: 1'b0 means "held down", which
        // latches the on-site test mode at power-up.  Keep it released, and
        // drive it only from the wavetable-mode test at the end.
        .vup_sw   (vup_sw),
        .test_sw  (1'b0),
        .key_btn  (key_btn),
        .tp_scl   (tp_scl),
        .i2s_bclk (i2s_bclk),
        .i2s_lrclk(i2s_lrclk),
        .i2s_din  (i2s_din),
        .lcd_dclk (lcd_dclk),
        .lcd_hs   (lcd_hs),
        .lcd_vs   (lcd_vs),
        .lcd_de   (lcd_de),
        .lcd_r    (lcd_r),
        .lcd_g    (lcd_g),
        .lcd_b    (lcd_b)
    );

    ttp229_model #(.IDLE_CLK(20), .ACTIVE_LOW(1)) u_model (
        .clk  (dut.clk_sys),
        .rst_n(dut.srst_n),
        .scl  (tp_scl),
        .keys (keys),
        .sdo  (tp_sdo)
    );

    // monitor the internal pixels of lcd_scope directly (ph == 10)
    integer dbg_px = 0;
    integer p_bar_lo = 0;
    integer p_kx0 = -1, p_kx1 = -1;
    integer p_kn = 0;
    integer p_zn = 0;
    reg [31:0] p_krows = 32'd0;
    reg prev_out_ph = 1'b0;
    integer i_key = 0, i_wave = 0, i_bar = 0;
    integer pi, nz;
    integer i_wave_rows = 0;
    reg [63:0] i_wrows;
    initial begin i_wrows = 64'd0; end
    always @(posedge clk) begin
        prev_out_ph <= dut.u_lcd.out_ph;
    end
    always @(posedge clk) begin
        if (prev_out_ph) begin
            if (dbg_px < 3) begin
                $display("px%0d x=%0d y=%0d ph=%0d rgb=%0d/%0d/%0d key_q=%b",
                         dbg_px, dut.u_lcd.x_q, dut.u_lcd.y_q, dut.u_lcd.ph,
                         dut.u_lcd.nr, dut.u_lcd.ng, dut.u_lcd.nb, dut.u_lcd.key_q);
                dbg_px = dbg_px + 1;
            end
            if (1'b0) begin
                $display("ph10 x=%0d y=%0d nr=%0d ng=%0d nb=%0d key_q=%b gate=%b kcell=%0d",
                         dut.u_lcd.x, dut.u_lcd.y,
                         dut.u_lcd.nr, dut.u_lcd.ng, dut.u_lcd.nb,
                         dut.u_lcd.key_q, dut.u_lcd.key_gate, dut.u_lcd.kcell);
            end
            if (dut.u_lcd.x_q < 480 && dut.u_lcd.y_q < 272) begin
                if (dut.u_lcd.nr==5'd31 && dut.u_lcd.ng==6'd44 && dut.u_lcd.nb==5'd0)
                    i_key = i_key + 1;
                if (dut.u_lcd.nr==5'd5 && dut.u_lcd.ng==6'd58 && dut.u_lcd.nb==5'd14) begin
                    i_wave = i_wave + 1;
                    if (dut.u_lcd.y_q >= 28 && dut.u_lcd.y_q < 92 &&
                        !i_wrows[dut.u_lcd.y_q - 28])
                        i_wrows[dut.u_lcd.y_q - 28] = 1'b1;
                end
                if (dut.u_lcd.nr==5'd31 && dut.u_lcd.ng==6'd52 && dut.u_lcd.nb==5'd31)
                    i_bar = i_bar + 1;
            end
        end
    end

    integer sampled = 0;
    always @(posedge clk) if (dut.sample_tick) sampled = sampled + 1;

    integer q; always @(*) begin i_wave_rows = 0; for (q=0;q<64;q=q+1) i_wave_rows = i_wave_rows + i_wrows[q]; end

    wire clk      = dut.clk_sys;
    wire pix_tick = dut.u_lcd.u_tmg.pix_tick;

    //----------------------------------------------------------------------
    // pass / fail bookkeeping
    //----------------------------------------------------------------------
    integer errors = 0;

    task chk;
        input            cond;
        input [8*80-1:0] name;
        begin
            if (cond) begin
                $display("PASS  %0s", name);
            end else begin
                $display("FAIL  %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_num;
        input [31:0]     got;
        input [31:0]     want;
        input [8*80-1:0] name;
        begin
            if (got === want) begin
                $display("PASS  %0s : %0d", name, got);
            end else begin
                $display("FAIL  %0s : got %0d want %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    //----------------------------------------------------------------------
    // colour codes as driven by lcd_scope.v
    //----------------------------------------------------------------------
    wire key_amber  = (lcd_r==5'd31) && (lcd_g==6'd44) && (lcd_b==5'd0);
    wire wave_green = (lcd_r==5'd5)  && (lcd_g==6'd58) && (lcd_b==5'd14);
    wire env_cyan   = (lcd_r==5'd3)  && (lcd_g==6'd50) && (lcd_b==5'd30);
    wire env_fill   = (lcd_r==5'd1)  && (lcd_g==6'd16) && (lcd_b==5'd28);
    wire bar_head   = (lcd_r==5'd31) && (lcd_g==6'd52) && (lcd_b==5'd31);
    //  spectrum page (dmode == 1): bar body and bar head colours
    wire spec_body  = (lcd_r==5'd2)  && (lcd_g==6'd30) && (lcd_b==5'd20);
    wire spec_head  = (lcd_r==5'd31) && (lcd_g==6'd52) && (lcd_b==5'd10);
    //  Lissajous page (dmode == 2): the filled X-Y figure
    wire liss_band  = (lcd_r==5'd22) && (lcd_g==6'd26) && (lcd_b==5'd31);

    //----------------------------------------------------------------------
    // pixel / frame statistics, plus HS and VS period measurement
    //----------------------------------------------------------------------
    integer col = 0, row = -1, frame_no = 0;
    reg     de_q = 1'b0;

    integer s_key = 0, s_wave = 0, s_envl = 0, s_envf = 0, s_bar = 0;
    integer s_spec = 0, s_spec_head = 0;
    integer s_liss = 0, s_liss_cols = 0;
    reg [511:0] s_lissrow;   // which rows the figure hits
    integer s_nwrows = 0, s_nkcells = 0, s_nbcells = 0;
    integer s_wrow0 = -1;   // row hit by the waveform at column 0 (trigger check)
    reg [135:0] s_wrows;          // waveform rows 28..163
    reg [7:0]   s_kcells, s_bcells;
    reg [15:0]  s_specbars;       // spectrum page: which of the 16 bars are lit

    integer f_key = 0, f_wave = 0, f_envl = 0, f_envf = 0, f_bar = 0;
    integer f_spec = 0, f_spec_head = 0;
    integer f_liss = 0, f_liss_cols = 0;
    reg [15:0] f_specbars;
    integer f_nwrows = 0, f_nkcells = 0, f_nbcells = 0;
    integer f_wrow0 = -1;

    integer dclk_cnt = 0, dclk_per = 0;
    reg     dclk_q = 1'b0;

    integer hs_pix = 0, hs_per = 0, hs_lines = 0, vs_per = 0;
    reg     hs_q = 1'b1, vs_q = 1'b1;

    integer kcell;

    // raw per-frame colour tallies for debugging the palette
    integer s_dbg_wave = 0, s_dbg_key = 0, s_dbg_env = 0, s_dbg_fill = 0, s_dbg_bar = 0;
integer p_bcols [0:129];
integer p_bn = 0;
integer p_dcmin = 32767, p_dcmax = -32768, p_ycmin = 32767, p_ycmax = -32768;
integer bi;
    integer f_dbg_wave = 0, f_dbg_key = 0, f_dbg_env = 0, f_dbg_fill = 0, f_dbg_bar = 0;
    integer s_px = 0;
    reg [4:0] dbg_r; reg [5:0] dbg_g; reg [4:0] dbg_b;
    always @(posedge clk) begin
        if (pix_tick && lcd_de && dut.u_lcd.y == 10'd10 && dut.u_lcd.x == 10'd5) begin
            dbg_r <= lcd_r; dbg_g <= lcd_g; dbg_b <= lcd_b;
        end
    end

    //----------------------------------------------------------------------
    // I2S din activity.  "No sound" with a perfect picture meant the DAC was
    // fed a constant, so counting transitions on din is the direct regression
    // for the mute-wired-to-a-pulled-up-key bug: a squashed-to-zero sample
    // stream toggles din almost never, a real one toggles thousands of times
    // per video frame.
    //----------------------------------------------------------------------
    reg          din_q = 1'b0;
    integer      din_edges = 0;
    integer      din0 = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            din_q     <= 1'b0;
            din_edges <= 0;
        end else begin
            din_q <= i2s_din;
            if (i2s_din && !din_q) din_edges <= din_edges + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            col = 0; row = -1; frame_no = 0;
            s_key = 0; s_wave = 0; s_envl = 0; s_envf = 0; s_bar = 0;
            s_nwrows = 0; s_nkcells = 0; s_nbcells = 0; s_wrow0 = -1;
            s_wrows = 0; s_kcells = 0; s_bcells = 0;
            s_spec = 0; s_spec_head = 0; s_specbars = 0;
        s_liss = 0; s_liss_cols = 0; s_lissrow = 0;
            s_dbg_wave = 0; s_dbg_key = 0; s_dbg_env = 0; s_dbg_fill = 0; s_dbg_bar = 0;
            f_dbg_wave = 0; f_dbg_key = 0; f_dbg_env = 0; f_dbg_fill = 0; f_dbg_bar = 0;
            f_key = 0; f_wave = 0; f_envl = 0; f_envf = 0; f_bar = 0;
            f_nwrows = 0; f_nkcells = 0; f_nbcells = 0; f_wrow0 = -1;
            dclk_cnt = 0; dclk_per = 0; dclk_q = 1'b0;
            hs_pix = 0; hs_per = 0; hs_lines = 0; vs_per = 0;
            hs_q = 1'b1; vs_q = 1'b1;
        end else begin
            //----------------------------------------------------------------
            // DCLK half period in sys clocks  (compare BEFORE updating dclk_q)
            //----------------------------------------------------------------
            if (dclk_q != lcd_dclk) begin
                if (dclk_cnt != 0) dclk_per = dclk_cnt + 1;
                dclk_cnt = 0;
            end else begin
                dclk_cnt = dclk_cnt + 1;
            end
            dclk_q = lcd_dclk;

            // The panel pins are REGISTERED on out_ph, so from the next clock
            // onwards they carry this pixel.  Sample exactly then, once per
            // pixel: sampling on out_ph itself would read the previous pixel's
            // colours (one pixel of lag on every region boundary).
            if (prev_out_ph) begin
                //------------------------------------------------------------
                // HS / VS periods
                //------------------------------------------------------------
                hs_pix = hs_pix + 1;
                if (hs_q && !lcd_hs) begin
                    hs_per  = hs_pix;
                    hs_pix  = 0;
                    hs_lines = hs_lines + 1;
                end
                if (vs_q && !lcd_vs) begin
                    vs_per   = hs_lines;
                    hs_lines = 0;
                    row      = -1;          // next active line becomes row 0
                end
                hs_q = lcd_hs;
                vs_q = lcd_vs;

                //------------------------------------------------------------
                // Walk the active area itself, so our (col,row) can never drift
                // out of step with the pixel that is actually on the wires.
                // col/row advance only while lcd_de is high.
                //------------------------------------------------------------
                if (lcd_de) begin
                    // Take the coordinates from the DUT itself.  lcd_de and
                    // lcd_r/g/b are latched from the same pixel, and x_q / y_q
                    // hold exactly that pixel's position, so no local counter
                    // can drift out of step.
                    // x_q / y_q already hold the NEXT pixel here (they are
                    // registered alongside the colour that was latched into
                    // or_/og/ob one clock ago), so take the coordinates that
                    // actually travelled with the colour on the wires.
                    col = dut.u_lcd.px_q;
                    row = dut.u_lcd.py_q;

                    if (row == 0 && col < 4 && p_zn < 8) begin
                        $display("ZERO col=%0d row=%0d de=%b pin=%0d/%0d/%0d xq=%0d yq=%0d tx=1",
                                 col, row, lcd_de, lcd_r, lcd_g, lcd_b,
                                 dut.u_lcd.x_q, dut.u_lcd.y_q);
                        p_zn = p_zn + 1;
                    end
                    if (row >= 0 && row < 272 && col < 480) begin
                        s_px = s_px + 1;
                        if (wave_green) s_dbg_wave = s_dbg_wave + 1;
                        if (key_amber)  s_dbg_key  = s_dbg_key  + 1;
                        if (env_cyan)   s_dbg_env  = s_dbg_env  + 1;
                        if (env_fill)   s_dbg_fill = s_dbg_fill + 1;
                        if (bar_head)   s_dbg_bar  = s_dbg_bar  + 1;
                        if (row < 240 && (lcd_r==5'd31) && (lcd_g==6'd52) && (lcd_b==5'd31))
                            p_bar_lo = p_bar_lo + 1;
                        if ($signed(dut.u_lcd.dc_w) < $signed(p_dcmin[15:0])) p_dcmin = dut.u_lcd.dc_w;
                        if ($signed(dut.u_lcd.dc_w) > $signed(p_dcmax[15:0])) p_dcmax = dut.u_lcd.dc_w;
                        if (row < 28) begin
                            if (key_amber) begin
                                s_key = s_key + 1;
                                if (p_kx0 < 0) p_kx0 = col;
                                if (col > p_kx1) p_kx1 = col;
                                if (p_kn < 3)
                                    $display("KPB col=%0d row=%0d de=%b r=%0d x=%0d xq=%0d kq=%b",
                                             col, row, lcd_de, lcd_r,
                                             dut.u_lcd.x, dut.u_lcd.x_q,
                                             dut.u_lcd.key_q);
                                p_kn = p_kn + 1;
                                p_krows[row] = 1'b1;
                                kcell = (col >= 480) ? 7 : (col / 60);
                                if (!s_kcells[kcell]) begin
                                    s_kcells[kcell] = 1'b1;
                                    s_nkcells = s_nkcells + 1;
                                end
                            end
                        end else if (row < 164) begin
                            if (liss_band) begin
                                s_liss = s_liss + 1;
                                if (!s_lissrow[col]) begin
                                    s_lissrow[col] = 1'b1;
                                    s_liss_cols = s_liss_cols + 1;
                                end
                            end else if (spec_body || spec_head) begin
                                s_spec = s_spec + 1;
                                if (spec_head) begin
                                    s_spec_head = s_spec_head + 1;
                                    s_specbars[col/30] = 1'b1;
                                end
                            end else if (wave_green) begin
                                s_wave = s_wave + 1;
                                if (!s_wrows[row-28]) begin
                                    s_wrows[row-28] = 1'b1;
                                    s_nwrows = s_nwrows + 1;
                                    // Remember the ROW of the very first trace
                                    // pixel in the frame.  This used to key off
                                    // scope column 0, but the trace at column 0
                                    // also draws the vertical connector to the
                                    // previous point, so "the first pixel of
                                    // column 0" is not well defined.  The first
                                    // pixel of the frame is: with the page now
                                    // showing a frozen snapshot, consecutive
                                    // frames must put it on the same row.
                                    if (s_wrow0 < 0) s_wrow0 = row;
                                end
                            end
                        end else if (row < 232) begin
                            if (env_cyan)      s_envl = s_envl + 1;
                            else if (env_fill) s_envf = s_envf + 1;
                        end else if (row >= 240) begin
                            if (bar_head) begin
                                s_bar = s_bar + 1;
                                if (col < 130) p_bcols[col] = p_bcols[col] + 1;
                                kcell = (col >= 480) ? 7 : (col / 60);
                                if (!s_bcells[kcell]) begin
                                    s_bcells[kcell] = 1'b1;
                                    s_nbcells = s_nbcells + 1;
                                end
                            end
                        end
                    end
                end
                //------------------------------------------------------------
                // frame boundary = end of the last active line (row 271).
                // de_q still holds the previous value here, so this sees the
                // falling edge of lcd_de.
                //------------------------------------------------------------
                if (de_q && !lcd_de && row >= 271) begin
                    f_key = s_key;      f_wave  = s_wave;
                    f_envl = s_envl;    f_envf  = s_envf;
                    f_bar = s_bar;
                    f_nwrows = s_nwrows;
                    f_wrow0  = s_wrow0;
                    f_nkcells = s_nkcells;
                    f_nbcells = s_nbcells;
                    f_spec = s_spec;    f_spec_head = s_spec_head;
        f_liss = s_liss;    f_liss_cols = s_liss_cols;
                    f_specbars = s_specbars;
                    f_dbg_wave = s_dbg_wave; f_dbg_key = s_dbg_key;
                    f_dbg_env = s_dbg_env;   f_dbg_fill = s_dbg_fill;
                    f_dbg_bar = s_dbg_bar;
                    s_dbg_wave = 0; s_dbg_key = 0; s_dbg_env = 0;
                    s_dbg_fill = 0; s_dbg_bar = 0;
                    s_key = 0; s_wave = 0; s_envl = 0; s_envf = 0; s_bar = 0;
                    s_nwrows = 0; s_nkcells = 0; s_nbcells = 0; s_wrow0 = -1;
                    s_wrows = 0; s_kcells = 0; s_bcells = 0;
                    s_spec = 0; s_spec_head = 0; s_specbars = 0;
        s_liss = 0; s_liss_cols = 0; s_lissrow = 0;
                    frame_no = frame_no + 1;
                end
                de_q = lcd_de;
            end
        end
    end

    //----------------------------------------------------------------------
    // helpers
    //----------------------------------------------------------------------
    task wait_frames;
        input integer n;
        integer g;
        begin
            g = 0;
            while ((frame_no < n) && (g < 6000000)) begin
                g = g + 1;
                @(posedge clk);
            end
            if (frame_no < n) begin
                $display("FAIL  wait_frames(%0d) timed out at frame %0d", n, frame_no);
                errors = errors + 1;
            end
        end
    endtask

    //----------------------------------------------------------------------
    // wait for the next audio sample tick (needed by the Key_3 long-press
    // test, because keymap8 counts hold time on the sample tick)
    //----------------------------------------------------------------------
    task wait_one_sample;
        integer g;
        begin
            g = 0;
            // step off a tick boundary first so we cannot return immediately
            @(posedge clk);
            while (!dut.sample_tick && (g < 8000)) begin
                g = g + 1;
                @(posedge clk);
            end
        end
    endtask

    //----------------------------------------------------------------------
    // audio probe: min / max of the mixer output, reset by the test phases
    //----------------------------------------------------------------------
    integer wmin = 0, wmax = 0;

    integer dbg_cnt = 0;
    always @(posedge clk) begin
        dbg_cnt = dbg_cnt + 1;
        if (rst_n) begin
            if ($signed(dut.mix_out) < wmin) wmin = $signed(dut.mix_out);
            if ($signed(dut.mix_out) > wmax) wmax = $signed(dut.mix_out);
        end
    end
    //----------------------------------------------------------------------
    // stimulus
    //----------------------------------------------------------------------
    integer base = 0;
    integer wrow0_a = 0, wrow0_b = 0;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_inst.vcd");
            $dumpvars(0, tb_inst);
        end

        $display("tb_inst: power-on");
        #2000;
        rst_n = 1'b1;
        $display("tb_inst: sine rom[0]=%h rom[256]=%h", dut.u_osc.u_wav.rom[0], dut.u_osc.u_wav.rom[256]);
        $display("tb_inst: reset released");

        //------------------------------------------------------------------
        // 1. idle -- nothing pressed
        //------------------------------------------------------------------
        wait_frames(3);
        $display("tb_inst: %0d frames rendered", frame_no);

        $display("");
        $display("---- idle (no touch) ----");
        $display("      idle frame colours seen:");
        chk_num(dclk_per, 2,  "DCLK half period in sys clocks (DIV/2)");
        chk_num(hs_per, 525,  "HS period in pixels");
        chk(vs_per >= 284 && vs_per <= 288, "VS period about 286 lines");
        chk_num(f_nkcells, 0, "no key cell lit while idle");
        chk_num(f_nbcells, 0, "no envelope bar lit while idle");
        chk(f_envf <= 4, "no envelope fill while idle");
        chk(f_envl <= 520, "envelope curve is a flat line while idle");
        $display("      idle wave trace pixels = %0d over %0d rows",
                 f_wave, f_nwrows);
        $display("      idle histogram: wave-green=%0d key-amber=%0d env-cyan=%0d env-fill=%0d bar=%0d",
                 f_dbg_wave, f_dbg_key, f_dbg_env, f_dbg_fill, f_dbg_bar);
        $display("      pixels walked: %0d, frames: %0d", s_px, frame_no);
        $display("      raw rgb at (row=10,col=5): %b/%b/%b", dbg_r, dbg_g, dbg_b);
        chk(f_nwrows <= 2, "idle waveform is one flat line");

        //------------------------------------------------------------------
        // 2. one key down
        //------------------------------------------------------------------
        keys = 16'h0001; wmin = 0; wmax = 0;
        base = frame_no;
        wait_frames(base + 4);

        $display("");
        $display("---- one key down (TP0 = C4) ----");
        $display("      key px = %0d cells = %0d | wave px = %0d rows = %0d",
                 f_key, f_nkcells, f_wave, f_nwrows);
        $display("      env curve px = %0d fill px = %0d | bar px = %0d cells = %0d",
                 f_envl, f_envf, f_bar, f_nbcells);
        $display("      mix_out min = %0d max = %0d", wmin, wmax);
        $display("      INTERNAL: key=%0d wave=%0d rows=%0d bar=%0d", i_key, i_wave, i_wave_rows, i_bar);
        $display("      key_gate=%b env0=%0d sample_tick_seen=%0d lat_mode=%b",
                 dut.gate, dut.env_flat[15:0], sampled, dut.latch_mode);
        for (bi = 0; bi < 130; bi = bi + 1)
            if (p_bcols[bi] != 0) $display("      BARCOL %0d -> %0d", bi, p_bcols[bi]);
        $display("      PROBE dc range: %0d .. %0d", $signed(p_dcmin[15:0]), $signed(p_dcmax[15:0]));
        $display("      PROBE env: base_e=%0d wra=%0d", dut.u_lcd.base_e, dut.wptr_e);
        nz = 0;
        for (pi = 0; pi < 512; pi = pi + 1) if (dut.u_lcd.u_buf_e.mem[pi] != 16'd0) begin
            $display("        mem_e[%0d] = %0d", pi, dut.u_lcd.u_buf_e.mem[pi]);
            nz = nz + 1;
        end
        $display("        nonzero env entries = %0d", nz);
        $display("      PROBE samp: s_cur=%0d s_prev=%0d yc=%0d ycp=%0d base_w=%0d wraddr=%0d",
                 $signed(dut.u_lcd.s_cur), $signed(dut.u_lcd.s_prev),
                 $signed(dut.u_lcd.yc_q), $signed(dut.u_lcd.ycp_q),
                 dut.u_lcd.base_w, dut.u_lcd.wr_addr_w);
        $display("      PROBE bars: head_below_240=%0d  btop=%0d  lev=%0d  env0=%0d",
                 p_bar_lo, dut.u_lcd.btop_q, dut.u_lcd.lev_q, dut.env_flat[15:0]);
        $display("      PROBE kcell=%0d envsec=%0d env_flat=%h",
                 dut.u_lcd.kcell, dut.u_lcd.env_flat[63:0], dut.env_flat);
        $display("      PROBE keys: amber rows seen=%b  col range=%0d..%0d",
                 p_krows, p_kx0, p_kx1);
        chk_num(f_nkcells, 1, "exactly one key cell lit");
        chk(f_nwrows > 20, "waveform trace spans many rows (a real sine)");
        chk(f_wave > 400,  "waveform trace has enough pixels");
        chk(f_envl > 40,   "envelope curve is drawn");
        chk(f_envf > 800,  "envelope area fill is drawn");
        chk_num(f_nbcells, 1, "exactly one envelope bar lit");
        chk(f_bar > 100,   "envelope bar has height");

        //------------------------------------------------------------------
        // 2a. audio really leaves the chip.  The panel is fed from the same
        //     mixer node as the I2S transmitter, so a perfect picture proves
        //     nothing about din -- the old build showed a clean sine while the
        //     DAC received a constant zero because mute was tied to a key whose
        //     net the Dock pulls up to +1V5.
        //------------------------------------------------------------------
        din0 = din_edges;
        base = frame_no;
        wait_frames(base + 1);
        $display("      din rising edges in one video frame = %0d",
                 din_edges - din0);
        chk((din_edges - din0) > 200,
            "I2S din keeps toggling while a note sounds (not muted)");


        //------------------------------------------------------------------
        // 2b. the scope is trigger-assisted, not trigger-locked.  A window is
        //     480 samples and the note's period is 184, so a frame can only be
        //     started on a crossing that is at least 480 samples old; the queue
        //     of recent crossings picks the oldest one that qualifies, which
        //     keeps the trace nearly still but cannot make it mathematically
        //     stationary (480 is not a multiple of 184).  What MUST hold is that
        //     the displayed samples stay inside written history -- i.e. the
        //     newest column is never ahead of the write pointer -- and that the
        //     trace keeps spanning the whole width of the box.
        //------------------------------------------------------------------
        $display("      FRAME-A base_w=%0d mem=%0d prev=%0d", dut.u_lcd.base_w,
                 $signed(dut.u_lcd.u_buf_w.mem[dut.u_lcd.base_w]),
                 $signed(dut.u_lcd.u_buf_w.mem[dut.u_lcd.base_w - 10'd1]));
        wrow0_a = f_wrow0;
        base = frame_no;
        wait_frames(base + 2);        $display("      FRAME-B base_w=%0d mem=%0d prev=%0d", dut.u_lcd.base_w,
                 $signed(dut.u_lcd.u_buf_w.mem[dut.u_lcd.base_w]),
                 $signed(dut.u_lcd.u_buf_w.mem[dut.u_lcd.base_w - 10'd1]));
        wrow0_b = f_wrow0;

        $display("");
        $display("---- scope window ----");
        $display("      trace row at column 0 : frame A = %0d  frame B = %0d",
                 wrow0_a, wrow0_b);
        $display("      base_w=%0d cap_run=%b cap_cnt=%0d",
                 dut.u_lcd.base_w, dut.cap_run, dut.cap_cnt);
        // Both frames must draw a real trace near the middle of the box: a
        // window that reached past the write pointer would read zeros there.
        chk(wrow0_a > 28 && wrow0_a < 164 && wrow0_b > 28 && wrow0_b < 164,
            "both frames draw the trace inside the waveform box");
        chk(f_nwrows > 80, "trace still spans most of the box height");
        // REGRESSION for the "the waveform never stops scrolling" bug: the
        // window origin used to be re-latched on x == 0 of EVERY row, so each
        // of the 272 lines started at a different phase and the picture sheared
        // downwards frame after frame.  With exactly one snapshot per frame a
        // steady tone must land on the same rows, allowing only the one-sample
        // quantisation of the zero crossing (about 2 of the 136 rows).
        $display("      |row(A) - row(B)| = %0d rows",
                 (wrow0_a > wrow0_b) ? (wrow0_a - wrow0_b) : (wrow0_b - wrow0_a));
        chk(((wrow0_a > wrow0_b) ? (wrow0_a - wrow0_b) : (wrow0_b - wrow0_a)) <= 3,
            "waveform is stationary between frames (one snapshot per frame)");

        //------------------------------------------------------------------
        // 3. two keys down at the same time -- polyphony
        //------------------------------------------------------------------
        keys = 16'h0003; wmin = 0; wmax = 0;
        base = frame_no;
        wait_frames(base + 4);

        $display("");
        $display("---- two keys down (TP0 + TP1) ----");
        $display("      key px = %0d cells = %0d | wave px = %0d rows = %0d",
                 f_key, f_nkcells, f_wave, f_nwrows);
        $display("      bar px = %0d cells = %0d", f_bar, f_nbcells);
        chk_num(f_nkcells, 2, "two key cells lit at once");
        chk_num(f_nbcells, 2, "two envelope bars lit at once");
        chk(f_wave > 400,   "waveform still drawn with two voices");

        //------------------------------------------------------------------
        // 4. release
        //------------------------------------------------------------------
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 3);

        $display("");
        $display("---- all released ----");
        $display("      key px = %0d cells = %0d", f_key, f_nkcells);
        chk_num(f_nkcells, 0, "key cells go dark again");

        //------------------------------------------------------------------
        // 5. latch (hold) mode -- the TTP229 chip only reports ONE pad at a
        //    time, so a real two-finger chord is impossible in hardware.
        //    Silicon Key_2 toggles latch mode: each tap toggles its note, so
        //    a chord can be built one finger at a time.
        //------------------------------------------------------------------
        key_btn = 1'b0;
        repeat (6) @(posedge clk);
        key_btn = 1'b1;
        repeat (6) @(posedge clk);
        chk(dut.latch_mode == 1'b1, "Key_2 toggles latch mode on");

        // tap TP0
        keys = 16'h0001;
        base = frame_no;
        wait_frames(base + 3);
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 3);
        chk(dut.latch[0] == 1'b1, "tap on TP0 latches note 0");

        // tap TP1
        keys = 16'h0002;
        base = frame_no;
        wait_frames(base + 3);
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 4);

        $display("");
        $display("---- latch mode: taps on TP0 then TP1, nothing held ----");
        $display("      latch = %02x  key px = %0d cells = %0d  bars = %0d",
                 dut.latch, f_key, f_nkcells, f_nbcells);
        chk_num(dut.latch, 8'h03,            "two notes latched");
        chk_num(f_nkcells, 2,                "two key cells lit with nothing held");
        chk_num(f_nbcells, 2,                "two envelope bars lit with nothing held");
        chk(f_nwrows > 20, "both latched notes are audible (waveform alive)");

        // latch off again -> everything goes dark
        key_btn = 1'b0;
        repeat (6) @(posedge clk);
        key_btn = 1'b1;
        base = frame_no;
        wait_frames(base + 4);

        $display("");
        $display("---- latch mode off ----");
        $display("      latch = %02x  key px = %0d cells = %0d",
                 dut.latch, f_key, f_nkcells);
        chk(dut.latch_mode == 1'b0, "Key_2 toggles latch mode off");
        chk_num(dut.latch, 8'h00,  "leaving latch mode clears it");
        chk_num(f_nkcells, 0,      "key cells go dark");

        //------------------------------------------------------------------
        // wavetable mode: a LONG Key_3 press toggles it, a SHORT press only
        // steps the volume.  WHOLD is 4 samples here, so hold for 12 samples.
        //------------------------------------------------------------------
        chk(dut.wave_mode == 1'b0, "wavetable mode is off after reset");

        // short press (2 samples) -> volume only, no mode change
        begin : short_press
            reg [3:0] vol_before;
            vol_before = dut.vol_raw;
            vup_sw = 1'b0;
            repeat (2) wait_one_sample;
            vup_sw = 1'b1;
            repeat (4) wait_one_sample;
            chk(dut.wave_mode == 1'b0, "short Key_3 press does not change wavetable mode");
            chk(dut.vol_raw != vol_before, "short Key_3 press still steps the volume");
        end

        // long press -> mode toggles on, and stays on after release
        begin : long_press_on
            vup_sw = 1'b0;
            repeat (16) wait_one_sample;
            vup_sw = 1'b1;
            repeat (4) wait_one_sample;
            chk(dut.wave_mode == 1'b1, "long Key_3 press switches wavetable mode on");
            $display("      wave_mode = %b (component c now reads table c;", dut.wave_mode);
            $display("                   tb_osc_bank proves tab_q == cidx for every slot)");
            // still audible: the mixer must keep producing a live signal
            keys = 16'h0001;
            base = frame_no;
            wait_frames(base + 2);
            chk(f_nwrows > 20, "wavetable mode still shows a live waveform");
            keys = 16'h0000;
            base = frame_no;
            wait_frames(base + 2);
        end

        // long press again -> back to the original timbres
        begin : long_press_off
            vup_sw = 1'b0;
            repeat (16) wait_one_sample;
            vup_sw = 1'b1;
            repeat (4) wait_one_sample;
            chk(dut.wave_mode == 1'b0, "second long press switches wavetable mode off");
        end

        //------------------------------------------------------------------
        // expression bank (赛题拓展②): vibrato / echo / glide
        //   Key_2 short press  -> latch mode      (tested above)
        //   Key_2 long  press  -> fx_mode + 1     (BTHR is 40 clk here)
        // With fx_mode = 0 every one of the three is bypassed, so the sound
        // must be bit-identical to the pre-P2 build.
        //------------------------------------------------------------------
        chk(dut.fx_mode == 3'd0, "expression bank is bypassed after reset");
        chk(dut.u_echo.on == 1'b0, "echo line is off after reset");
        chk(dut.u_osc.vib_d == 6'sd0, "vibrato depth is zero after reset");
        chk(dut.glide_en == 1'b0, "glide is off after reset");

        // the glide lead note must be the note of the most recently pressed
        // pad.  note_flat packs 5 bits per voice, so this also pins down the
        // stride: a stride of 4 splices two adjacent notes together and the
        // glide would land on the wrong pitch (a real bug caught here).
        keys = 16'h0008;                       // TP3
        base = frame_no;
        wait_frames(base + 2);
        chk_num(dut.lead_note, dut.note_flat[15 +: 5],
            "glide lead note follows the newest pad (TP3)");
        keys = 16'h0020;                       // TP5
        base = frame_no;
        wait_frames(base + 2);
        chk_num(dut.lead_note, dut.note_flat[25 +: 5],
            "glide lead note follows the newest pad (TP5)");
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 2);

        // the echo line delays by exactly two samples whether it is on or off,
        // so the mixer -> audio_out handshake must keep a 1:1 pulse ratio.
        base = frame_no;
        begin : echo_tick_ratio
            integer n_ok, n_tick;
            n_ok   = 0;
            n_tick = 0;
            fork
                begin
                    wait_frames(base + 3);
                end
                begin
                    while (frame_no < (base + 3)) begin
                        @(posedge clk);
                        if (dut.mix_ok)  n_ok   = n_ok + 1;
                        if (dut.echo_tick) n_tick = n_tick + 1;
                    end
                end
            join
            chk_num(n_tick, n_ok, "echo passes exactly one valid pulse per mix");
        end

        // hold Key_2 long enough to step the FX bank once: vibrato on
        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd1, "long Key_2 press steps the FX bank to 1");
        chk(dut.fx_mode[0] == 1'b1, "FX = 1 selects the vibrato");

        // ... and a long press must NOT also toggle latch mode
        chk(dut.latch_mode == 1'b0,
            "a long Key_2 press does not toggle latch mode");

        // keep stepping: 1 -> 2 (glide) -> 3 (echo) -> ... -> 0
        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd2, "second long press steps the FX bank to 2");
        chk(dut.glide_en == 1'b1, "FX = 2 selects the glide");
        chk(dut.u_echo.on == 1'b0, "FX = 2 leaves the echo line off");

        // 2 -> 3 selects the echo (fx_mode is a PRESET index, not a bit mask)
        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd3, "third long press steps the FX bank to 3");
        chk(dut.u_echo.on == 1'b1, "FX = 3 switches the echo line on");
        chk(dut.glide_en == 1'b0, "FX = 3 leaves the glide off");

        // with the echo on the note must still sound, and the I2S word must
        // still be phase locked (din keeps toggling)
        keys = 16'h0001;
        base = frame_no;
        din0 = din_edges;
        wait_frames(base + 3);
        chk((din_edges - din0) > 200,
            "I2S din keeps toggling while the echo is on");
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 2);

        // step all the way round: 3 -> 4 -> 5 -> 6 -> 7 -> 0
        begin : fx_wrap
            integer st;
            for (st = 0; st < 5; st = st + 1) begin
                key_btn = 1'b0;
                repeat (60) @(posedge clk);
                key_btn = 1'b1;
                repeat (12) @(posedge clk);
            end
        end
        chk_num(dut.fx_mode, 3'd0, "FX bank wraps from 7 back to 0 (bypassed)");

        //------------------------------------------------------------------
        // reverb (4) and chorus (5) are presets 4 and 5, and 6/7 combine them
        //------------------------------------------------------------------
        begin : fx_rvb_cho
            integer st;
            for (st = 0; st < 4; st = st + 1) begin
                key_btn = 1'b0;
                repeat (60) @(posedge clk);
                key_btn = 1'b1;
                repeat (12) @(posedge clk);
            end
        end
        chk_num(dut.fx_mode, 3'd4, "FX bank reaches preset 4 (reverb)");
        chk(dut.rvb_on == 1'b1 && dut.u_echo.on == 1'b0 && dut.cho_on == 1'b0,
            "FX = 4 selects the reverb alone");

        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd5, "FX bank reaches preset 5 (chorus)");
        chk(dut.cho_on == 1'b1 && dut.rvb_on == 1'b0,
            "FX = 5 selects the chorus alone");

        // the chorus must not stop the note: din keeps toggling
        keys = 16'h0001;
        base = frame_no;
        din0 = din_edges;
        wait_frames(base + 3);
        chk((din_edges - din0) > 200,
            "I2S din keeps toggling while the chorus is on");
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 2);

        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd6, "FX bank reaches preset 6 (echo + reverb)");
        chk(dut.u_echo.on == 1'b1 && dut.rvb_on == 1'b1 && dut.cho_on == 1'b0,
            "FX = 6 selects echo plus reverb");

        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd7, "FX bank reaches preset 7 (everything)");
        chk(dut.u_echo.on == 1'b1 && dut.rvb_on == 1'b1 && dut.cho_on == 1'b1
            && dut.vib_on == 1'b1 && dut.glide_en == 1'b1,
            "FX = 7 turns every effect on");

        // back to 0 so the display-page test below starts from a clean bank
        key_btn = 1'b0;
        repeat (60) @(posedge clk);
        key_btn = 1'b1;
        repeat (12) @(posedge clk);
        chk_num(dut.fx_mode, 3'd0, "FX bank wraps back to 0 (bypassed)");

        //------------------------------------------------------------------
        // display page: a VERY long Key_2 press (2 x BTHR = 80 clk here)
        // besides stepping the FX bank, so the assertion below documents that
        // coexistence rather than pretending it does not happen.
        //------------------------------------------------------------------
        chk(dut.dmode == 2'd0, "display page starts on the waveform");
        key_btn = 1'b0;
        repeat (130) @(posedge clk);          // well past 2 x BTHR
        chk(dut.dmode == 2'd1,
            "a very long Key_2 press switches to the spectrum page");
        chk_num(dut.fx_mode, 3'd1,
                "the same very long press also stepped the FX bank once");
        key_btn = 1'b1;
        repeat (60) @(posedge clk);

        // NOTE: the position above left fx_mode = 1, i.e. the vibrato is ON, so
        // the pitch wobbles inside the analysis block and the bars spread over
        // several bins.  That is expected here -- tb_spec_cont proves the clean
        // case (a steady continuous-phase tone peaks in one bar).
        //
        // with a note sounding the spectrum must draw something.  One 512-point
        // block takes 512 samples (10.6 ms) and a frame is 16.7 ms, so give it
        // three frames before looking.
        keys = 16'h0001;
        base = frame_no;
        wait_frames(base + 3);
        $display("      spectrum px = %0d  head px = %0d  bars = %b",
                 f_spec, f_spec_head, f_specbars);
        chk((f_spec > 500), "spectrum page draws bars while a note sounds");
        chk((f_specbars != 16'd0), "at least one spectrum bar is lit");
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 2);

        //------------------------------------------------------------------
        // the second very long press moves on to the Lissajous page
        //------------------------------------------------------------------
        key_btn = 1'b0;
        repeat (130) @(posedge clk);
        chk(dut.dmode == 2'd2,
            "a second very long press switches to the Lissajous page");
        key_btn = 1'b1;
        repeat (60) @(posedge clk);

        // the figure is rebuilt once per frame from 512 stereo samples, so one
        // full frame of rendering is enough to have something to look at
        keys = 16'h0001;
        base = frame_no;
        wait_frames(base + 3);
        $display("      lissajous px = %0d  columns = %0d", f_liss, f_liss_cols);
        chk((f_liss > 500), "Lissajous page draws the X-Y figure while a note sounds");
        chk((f_liss_cols > 20),
            "the figure spreads over many columns, not a single vertical line");
        keys = 16'h0000;
        base = frame_no;
        wait_frames(base + 2);

        // and the third very long press wraps back to the waveform
        key_btn = 1'b0;
        repeat (130) @(posedge clk);
        chk(dut.dmode == 2'd0,
            "a third very long press returns to the waveform page");
        key_btn = 1'b1;
        repeat (60) @(posedge clk);

        //------------------------------------------------------------------
        if (errors == 0)
            $display("\n== tb_inst : ALL PASS ==");
        else
            $display("\n== tb_inst : %0d FAILURES ==", errors);
        $finish;
    end

endmodule
