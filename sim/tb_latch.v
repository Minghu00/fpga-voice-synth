//=============================================================================
//  tb_latch.v  --  tap-to-latch in top_inst must survive single-key reporting
//
//  WHY THIS EXISTS
//  ---------------
//  The TTP229 module ships strapped for its default single-key mode: with two
//  fingers down it reports ONE pad at a time and may hand out a different pad
//  on every 32 ms scan.  A latch rule of the form
//
//        latch <= latch ^ key_rise;
//
//  therefore toggled a note on when its pad won the scan and straight back
//  off when the other pad won the next one.  On hardware that is heard as the
//  two latched notes "trembling" a few dozen times a second.
//
//  This bench reproduces exactly that bit pattern on key_raw and pins down the
//  rule that fixes it:
//
//     A  alternating 0x0001 / 0x0002  -> both notes latch, then stay latched
//                                        no matter how long the chip keeps
//                                        alternating
//     B  everything released          -> notes stay latched (that is the
//                                        whole point of latch mode)
//     C  tap pad 0 again              -> only note 0 toggles off
//     D  both pads in one report      -> one toggle each, as before
//     E  keep holding                 -> no drift
//
//  TAP_HOLD is shrunk so the bench is fast; the rule it exercises is the same
//  one that runs at 965 samples on hardware.
//=============================================================================
`timescale 1ns / 1ps

module tb_latch;

    localparam integer TAP_HOLD = 8;
    localparam integer SCAN     = 20;        // one "chip scan", > TAP_HOLD

    reg        clk27  = 1'b0;
    reg        rst_n  = 1'b0;
    reg  [3:0] dip    = 4'b0000;
    wire       tp_scl, tp_sdo;
    wire       i2s_bclk, i2s_lrclk, i2s_din;
    wire       lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0] lcd_r;
    wire [5:0] lcd_g;
    wire [4:0] lcd_b;

    integer    errors = 0;
    integer    nr;

    always #18.5185 clk27 = ~clk27;          // 27 MHz

    top_inst #(
        .INIT_CLK  (60),
        .POLL_CLK  (400),
        .SCL_HALF  (8),
        .ACTIVE_LOW(1),
        .ATT_STEP  (100),
        .DEC_STEP  (2),
        .REL_STEP  (4),
        .SUSTAIN   (16'd40000),
        .DIV       (1000),                   // LCD is irrelevant here
        .WHOLD     (4),
        .BTHR      (40),
        .TAP_HOLD  (TAP_HOLD)
    ) dut (
        .clk27    (clk27),
        .rst_n    (rst_n),
        .tp_sdo   (tp_sdo),
        .dip      (dip),
        .sw5_vol  (1'b0),
        .vup_sw   (1'b1),
        .test_sw  (1'b0),
        .key_btn  (1'b1),
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

    task ticks;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge dut.sample_tick);
        end
    endtask

    task chk;
        input [8*40-1:0] what;
        input [7:0]      want;
        begin
            if (dut.latch !== want) begin
                $display("  FAIL  %0s : latch = %02h, want %02h",
                         what, dut.latch, want);
                errors = errors + 1;
            end else begin
                $display("  ok    %0s : latch = %02h", what, dut.latch);
            end
        end
    endtask

    initial begin
        $display("=== tb_latch: tap-to-latch vs single-key alternating reports ===");
        $display("    TAP_HOLD = %0d samples, one scan = %0d samples",
                 TAP_HOLD, SCAN);

        #200 rst_n = 1'b1;
        ticks(20);
        force dut.key_raw = 16'h0000;
        ticks(5);
        force dut.latch_mode = 1'b1;
        ticks(5);

        //---- A: the chip alternates between pad 0 and pad 1 ----------------
        force dut.key_raw = 16'h0001;
        ticks(SCAN);
        chk("A1 pad0 first report", 8'h01);
        force dut.key_raw = 16'h0002;
        ticks(SCAN);
        chk("A2 pad1 first report", 8'h03);

        for (nr = 0; nr < 3; nr = nr + 1) begin
            force dut.key_raw = 16'h0001;
            ticks(SCAN);
            chk("A3 pad0 again, no flap", 8'h03);
            force dut.key_raw = 16'h0002;
            ticks(SCAN);
            chk("A4 pad1 again, no flap", 8'h03);
        end

        //---- B: both fingers lifted -> re-arm, notes stay latched ----------
        force dut.key_raw = 16'h0000;
        ticks(60);
        chk("B  all up, keeps both", 8'h03);

        //---- C: tap pad 0 alone -> that note toggles OFF -------------------
        force dut.key_raw = 16'h0001;
        ticks(60);
        chk("C  pad0 tapped again", 8'h02);

        //---- D: both pads in one report -> one toggle each -----------------
        force dut.key_raw = 16'h0000;
        ticks(60);
        force dut.key_raw = 16'h0003;
        ticks(60);
        chk("D  both at once", 8'h01);

        //---- E: keep holding -> must not drift -----------------------------
        ticks(200);
        chk("E  still held, stable", 8'h01);

        if (errors == 0) begin
            $display("");
            $display("=== ALL PASS ===");
        end else begin
            $display("");
            $display("=== %0d FAILURE(S) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("=== TIMEOUT ===");
        $fatal(1);
    end

endmodule
