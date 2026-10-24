//=============================================================================
//  tb_lcd_test.v -- bring-up build self test
//
//  Checks
//    * DCLK is 108/12 = 9 MHz
//    * 525 x 286 timing, every active line carries exactly 480 DE pixels
//    * the screen is not blank: the colour histogram spans many values
//    * the red / green / blue ramp bands really ramp
//    * the key boxes light up when the touch model reports a key
//=============================================================================
`timescale 1ns / 1ps

module tb_lcd_test;

    localparam integer TR = 37;          // clk27 half period (ns) ~ 27 MHz

    reg clk27 = 1'b0;
    reg rst_n = 1'b0;

    always #(TR/2) clk27 = ~clk27;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire       tp_scl;
    wire       tp_sdo;
    wire       lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0] lcd_r;
    wire [5:0] lcd_g;
    wire [4:0] lcd_b;

    reg         tp_send = 1'b0;
    reg  [15:0] tp_keys = 16'h0000;

    top_lcd_test #(
        .WARM_CLK (60),
        .DV_QUAL  (20),
        .TW_CLK   (20),
        .SCL_HALF (8),
        .SLEEP_CLK(2000000)
    ) dut (
        .clk27   (clk27),
        .rst_n   (rst_n),
        .tp_sdo  (tp_sdo),
        .tp_scl  (tp_scl),
        .lcd_dclk(lcd_dclk),
        .lcd_hs  (lcd_hs),
        .lcd_vs  (lcd_vs),
        .lcd_de  (lcd_de),
        .lcd_r   (lcd_r),
        .lcd_g   (lcd_g),
        .lcd_b   (lcd_b)
    );

    // AUTO_CLK keeps frames flowing the way the real TTP229 does, so the
    // receiver never falls into its sleep watchdog while the test idles.
    ttp229_model #(.DV_CLK(50), .AUTO_CLK(3000)) u_model (
        .clk  (dut.clk_sys),
        .rst_n(dut.srst_n),
        .scl  (tp_scl),
        .send (tp_send),
        .keys (tp_keys),
        .sdo  (tp_sdo)
    );

    //------------------------------------------------------------------
    // pixel clock and counters
    //------------------------------------------------------------------
    wire clk = dut.clk_sys;
    wire tick = dut.pix_tick;

    integer dclk_cnt   = 0;
    integer dclk_per   = 0;
    integer px_cnt     = 0;
    integer hs_per     = 0;
    integer vs_per     = 0;
    integer lines      = 0;
    integer frame_no   = 0;
    integer de_line    = 0;
    integer bad_de     = 0;
    integer g_px       = 0;      // green counter, for the histogram test
    reg     dclk_q     = 1'b0;
    reg     hs_q       = 1'b1;
    reg     vs_q       = 1'b1;

    // pixels inside the key-box band (last 48 rows)
    integer k_band_lit = 0;
    // pixels in the r / g / b ramp bands whose channel is in the upper half
    integer ramp_r_hi  = 0;
    integer ramp_g_hi  = 0;
    integer ramp_b_hi  = 0;

    reg     counting   = 1'b0;
    reg     arm        = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            dclk_cnt <= 0;
        end else if (dclk_q != lcd_dclk) begin
            dclk_q   <= lcd_dclk;
            if (!dclk_q) dclk_per <= dclk_cnt + 1;
            dclk_cnt <= 0;
        end else begin
            dclk_cnt <= dclk_cnt + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && tick) begin
            // NOTE: hs_q / vs_q must also be updated only on a pixel tick,
            // otherwise the edge is consumed by one of the non-tick cycles.
            hs_q <= lcd_hs;
            vs_q <= lcd_vs;

            if (!lcd_hs && hs_q) begin
                if (px_cnt != 0) hs_per = px_cnt;
                // a line either carries a full active row or none at all
                if (de_line != 0 && de_line != 480) bad_de = bad_de + 1;
                px_cnt  = 0;
                de_line = 0;
                lines   = lines + 1;
            end
            px_cnt = px_cnt + 1;

            if (!lcd_vs && vs_q) begin
                if (lines != 0) vs_per = lines;
                lines    = 0;
                frame_no = frame_no + 1;

                // counters are gated to exactly one whole frame: arm at the
                // start of a frame, then stop at the start of the next one
                if (arm) begin
                    arm      = 1'b0;
                    counting = 1'b1;
                end else if (counting) begin
                    counting = 1'b0;
                end
            end

            if (lcd_de) begin
                de_line = de_line + 1;
                if (counting) begin
                    if (lcd_g > 6'd40) g_px = g_px + 1;

                    // NOTE: dut.y still holds the row of the pixel that was
                    // just finished, which is exactly the pixel whose colour
                    // is present on lcd_r/g/b right now.
                    if (dut.y >= 10'd224)
                        if (lcd_r == 5'd21 && lcd_g == 6'd63 && lcd_b == 5'd21)
                            k_band_lit = k_band_lit + 1;

                    // ramps: rows 48..95 (red), 96..143 (green),
                    //        144..191 (blue)
                    if (dut.y >= 10'd48 && dut.y < 10'd96)
                        if (lcd_r > 5'd16) ramp_r_hi = ramp_r_hi + 1;
                    if (dut.y >= 10'd96 && dut.y < 10'd144)
                        if (lcd_g > 6'd32) ramp_g_hi = ramp_g_hi + 1;
                    if (dut.y >= 10'd144 && dut.y < 10'd192)
                        if (lcd_b > 5'd16) ramp_b_hi = ramp_b_hi + 1;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // helpers
    //------------------------------------------------------------------
    integer failures = 0;
    integer chk      = 0;

    task check;
        input [511:0] name;
        input         ok;
        begin
            chk = chk + 1;
            if (ok) $display("PASS  %0s", name);
            else begin
                $display("FAIL  %0s", name);
                failures = failures + 1;
            end
        end
    endtask

    task check_num;
        input [511:0] name;
        input integer got;
        input integer want;
        begin
            chk = chk + 1;
            if (got == want) $display("PASS  %0s : %0d", name, got);
            else begin
                $display("FAIL  %0s : got %0d want %0d", name, got, want);
                failures = failures + 1;
            end
        end
    endtask

    task wait_frame;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while (frame_no < n && guard < 20000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    task reset_counters;
        begin
            g_px       = 0;
            k_band_lit = 0;
            ramp_r_hi  = 0;
            ramp_g_hi  = 0;
            ramp_b_hi  = 0;
            counting   = 1'b0;
            arm        = 1'b1;
        end
    endtask

    // wait until the gated frame has been captured
    task wait_one_frame;
        integer guard;
        begin
            guard = 0;
            while ((arm || counting) && guard < 4000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    integer r_before, k_before, f1, f2;

    //------------------------------------------------------------------
    // run
    //------------------------------------------------------------------
    initial begin
        // dumping every signal for several full frames produces a multi-GB
        // file, so only wave-dump when explicitly asked:  vvp ... +vcd
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_lcd_test.vcd");
            $dumpvars(0, tb_lcd_test);
        end

        rst_n = 1'b0;
        repeat (40) @(posedge clk27);
        rst_n = 1'b1;

        // let the PLL lock, the reset sync release and the touch model warm up
        wait_frame(2);
        wait_frame(4);

        $display("");
        $display("---- timing ----");
        check_num("DCLK half period in sys clocks (9 MHz)", dclk_per, 6);
        check_num("HS period in pixels", hs_per, 525);
        check_num("VS period in lines",  vs_per, 286);
        check_num("lines with wrong DE count", bad_de, 0);

        $display("");
        $display("---- picture, no key touched ----");
        reset_counters;
        wait_one_frame;
        $display("      green>40 pixels = %0d   key band lit = %0d", g_px, k_band_lit);
        $display("      ramp upper-half counts  R=%0d G=%0d B=%0d",
                 ramp_r_hi, ramp_g_hi, ramp_b_hi);

        check("screen is not blank", g_px > 2000);
        check("red ramp drives the upper half of its band",  ramp_r_hi > 10000 && ramp_r_hi < 11200);
        check("green ramp drives the upper half of its band", ramp_g_hi > 10000 && ramp_g_hi < 11200);
        check("blue ramp drives the upper half of its band",  ramp_b_hi > 10000 && ramp_b_hi < 11200);
        check_num("no key box lit while idle", k_band_lit, 0);

        k_before = k_band_lit;

        $display("");
        $display("---- press TP4 ----");
        tp_keys = 16'h0010;

        wait_frame(frame_no + 2);
        reset_counters;
        wait_one_frame;
        $display("      green>40 pixels = %0d   key band lit = %0d", g_px, k_band_lit);

        // box 4 covers x 120..149 over rows 224..271 -> exactly 30 x 48
        check_num("key box 4 lights up", k_band_lit, 30 * 48);
        check("key box count changed with the touch", k_band_lit > k_before);

        $display("");
        $display("---- release ----");
        tp_keys = 16'h0000;

        wait_frame(frame_no + 2);
        reset_counters;
        wait_one_frame;
        $display("      key band lit = %0d", k_band_lit);
        check_num("key boxes go dark again", k_band_lit, 0);

        $display("");
        if (failures == 0)
            $display("== tb_lcd_test : ALL PASS (%0d checks) ==", chk);
        else
            $display("== tb_lcd_test : %0d FAILURE(S) of %0d ==", failures, chk);

        $finish;
    end

    // absolute timeout
    initial begin
        #2000000000;
        $display("== tb_lcd_test : TIMEOUT ==");
        $finish;
    end

endmodule
