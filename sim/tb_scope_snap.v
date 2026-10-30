//=============================================================================
// tb_scope_snap.v -- the waveform page must be FROZEN, not scrolled
//
// History.  The scope page used to scroll: the window was anchored to the
// write pointer, and the display consumes 804 samples per frame while the
// history is only 1024 deep, so every frame showed a different slice.  Trigger
// schemes on carrier crossings and on the beat envelope were both tried and
// both failed for the same reason -- two tones are incommensurate, so the
// phase of whatever event you trigger on drifts from frame to frame.  Measured
// frame-to-frame MAD was 1500..2500 counts out of 32768: the trace visibly
// jumped.
//
// The fix is a single-shot snapshot: on a change of pressed pads, wait SETTLE
// audio samples, store 480 consecutive samples, then hold.  This bench proves
// the "hold" part by comparing the 480 samples the LCD actually reads on
// consecutive frames -- they must be bit-identical.
//
// Two snapshots are exercised: pads 0+1, then pad 0 alone.  The second one
// proves the capture re-arms when the pad set changes.
//=============================================================================
`timescale 1ns / 1ps

module tb_scope_snap;

    reg clk27 = 1'b0;
    reg rst_n = 1'b0;
    always #18.518 clk27 = ~clk27;      // 27 MHz

    reg  [3:0] dip     = 4'b0000;
    reg        key_btn = 1'b1;
    reg        vup_sw  = 1'b1;
    reg        tp_sdo  = 1'b1;
    reg        test_sw = 1'b0;
    reg        sw5_vol = 1'b0;

    wire tp_scl;
    wire i2s_bclk, i2s_lrclk, i2s_din;
    wire lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0] lcd_r, lcd_b;
    wire [5:0] lcd_g;

    top_inst #(
        .INIT_CLK (60),
        .POLL_CLK (400),
        .SCL_HALF (8),
        .WHOLD    (4),
        .BTHR     (40),
        .TAP_HOLD (40),
        .SETTLE   (400)                 // 8 ms instead of 300 ms
    ) dut (
        .clk27     (clk27),
        .rst_n     (rst_n),
        .tp_sdo    (tp_sdo),
        .tp_scl    (tp_scl),
        .key_btn   (key_btn),
        .vup_sw    (vup_sw),
        .test_sw   (test_sw),
        .sw5_vol   (sw5_vol),
        .dip       (dip),
        .i2s_bclk  (i2s_bclk),
        .i2s_lrclk (i2s_lrclk),
        .i2s_din   (i2s_din),
        .lcd_dclk  (lcd_dclk),
        .lcd_hs    (lcd_hs),
        .lcd_vs    (lcd_vs),
        .lcd_de    (lcd_de),
        .lcd_r     (lcd_r),
        .lcd_g     (lcd_g),
        .lcd_b     (lcd_b)
    );

    integer errors = 0;
    task chk;
        input cond;
        input [1023:0] what;
        begin
            if (cond) $display("  PASS  %0s", what);
            else begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // one frame = the 480 columns the LCD paints, sampled at VSYNC
    //-------------------------------------------------------------------------
    reg  vs_q = 1'b0;
    wire fstrt = vs_q & ~lcd_vs;
    always @(posedge dut.clk_sys) vs_q <= lcd_vs;

    reg signed [15:0] snap_a [0:479];
    reg signed [15:0] snap_b [0:479];
    integer i, k, dmax, frames, frozen, held_bad;
    reg signed [15:0] d;
    reg have_snap;

    initial begin
        frames    = 0;
        frozen    = 0;
        held_bad  = 0;
        have_snap = 1'b0;
        for (i = 0; i < 480; i = i + 1) begin
            snap_a[i] = 16'sd0;
            snap_b[i] = 16'sd0;
        end
    end

    // a capture burst that ends means the buffer now holds a snapshot
    reg cap_q = 1'b0;
    integer since_snap = 0;
    always @(posedge dut.clk_sys) begin
        cap_q <= dut.cap_run;
        if (cap_q && !dut.cap_run) begin
            have_snap  = 1'b1;
            since_snap = 0;             // the straddling frame is not judged
        end
    end

    //-------------------------------------------------------------------------
    // compare consecutive frames; a frozen display gives dmax == 0
    //-------------------------------------------------------------------------
    always @(posedge dut.clk_sys) begin
        if (fstrt) begin
            if (frames > 0) begin
                for (k = 0; k < 480; k = k + 1)
                    snap_b[k] = dut.u_lcd.u_buf_w.mem[k[9:0]];
                dmax = 0;
                for (k = 0; k < 480; k = k + 1) begin
                    d = snap_b[k] - snap_a[k];
                    if (d < 0) d = -d;
                    if (d > dmax) dmax = d;
                end
                // judge only frames that are not part of a capture burst, only
                // once a snapshot exists, and never the frame that witnessed the
                // burst finish (its predecessor was still filling)
                if (have_snap && !dut.cap_run && since_snap >= 1) begin
                    if (dmax != 0 && held_bad == 0) begin
                        $display("  FAIL  frozen trace: frame-to-frame dmax = %0d",
                                 dmax);
                        errors  = errors + 1;
                        held_bad = 1;
                    end
                    if (dmax == 0) frozen = frozen + 1;
                end
            end
            for (k = 0; k < 480; k = k + 1) snap_a[k] = snap_b[k];
            frames = frames + 1;
            if (have_snap) since_snap = since_snap + 1;
        end
    end

    //-------------------------------------------------------------------------
    // stimulus
    //-------------------------------------------------------------------------
    integer f_note2;

    initial begin
        #2000;
        rst_n = 1'b1;

        // ---- pads 0 + 1 ----------------------------------------------------
        #20000;
        force dut.key_raw = 16'h0003;
        wait (dut.cap_run == 1'b1);         // burst starts
        wait (dut.cap_run == 1'b0);         // buffer is full, now hold
        repeat (6) @(negedge lcd_vs);
        chk(have_snap == 1'b1,      "2-note snapshot captured");
        chk(held_bad == 0,          "trace is bit-identical across frames");
        f_note2 = frozen;
        chk(f_note2 >= 3,           "at least 3 frozen frames observed");

        // ---- drop to pad 0 only: the capture must re-arm -------------------
        have_snap = 1'b0;                   // cleared until the burst ends
        force dut.key_raw = 16'h0001;
        repeat (20) @(negedge lcd_vs);
        chk(have_snap == 1'b1,      "pad change re-armed the snapshot");
        repeat (4) @(negedge lcd_vs);
        chk(held_bad == 0,          "second snapshot is frozen too");

        $display("");
        if (errors == 0) $display("== tb_scope_snap : ALL PASS ==");
        else             $display("== tb_scope_snap : %0d FAILURE(S) ==", errors);
        $finish;
    end

    initial begin
        #600000000;
        $display("== tb_scope_snap : TIMEOUT ==");
        $finish;
    end

endmodule
