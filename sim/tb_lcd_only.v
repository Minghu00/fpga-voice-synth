//=============================================================================
//  tb_lcd_only.v -- self test for the display only bring-up top level
//
//  Everything is measured over exactly one frame: the counters are armed at a
//  vsync edge and read when the next vsync edge closes the window.
//=============================================================================
`timescale 1ns / 1ps

module tb_lcd_only;

    reg clk27 = 1'b0;
    reg rst_n = 1'b0;

    always #18 clk27 = ~clk27;          // ~27 MHz

    wire       lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0] lcd_r;
    wire [5:0] lcd_g;
    wire [4:0] lcd_b;

    top_lcd dut (
        .clk27   (clk27),
        .rst_n   (rst_n),
        .lcd_dclk(lcd_dclk),
        .lcd_hs  (lcd_hs),
        .lcd_vs  (lcd_vs),
        .lcd_de  (lcd_de),
        .lcd_r   (lcd_r),
        .lcd_g   (lcd_g),
        .lcd_b   (lcd_b)
    );

    wire clk  = dut.clk_sys;
    wire tick = dut.pix_tick;

    //------------------------------------------------------------------
    // timing measurement
    //------------------------------------------------------------------
    integer dclk_cnt = 0;
    integer dclk_per = 0;
    integer px_cnt   = 0;
    integer hs_per   = 0;
    integer vs_per   = 0;
    integer lines    = 0;
    integer de_line  = 0;
    integer bad_de   = 0;
    integer frame_no = 0;

    reg dclk_q = 1'b0;
    reg hs_q   = 1'b1;
    reg vs_q   = 1'b1;

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

    //------------------------------------------------------------------
    // per frame counters
    //------------------------------------------------------------------
    reg     counting = 1'b0;
    reg     arm      = 1'b0;

    integer ramp_r_hi = 0;
    integer ramp_g_hi = 0;
    integer ramp_b_hi = 0;
    integer blk_red   = 0;
    integer blk_green = 0;
    integer ruler_lit = 0;
    integer bars_lit  = 0;
    integer sweep_x   = 0;
    integer sweep_min = 4096;
    integer sweep_max = -1;

    always @(posedge clk) begin
        if (rst_n && tick) begin
            // sampled and compared at the same rate, otherwise the edge is
            // swallowed by one of the eleven non tick cycles
            hs_q <= lcd_hs;
            vs_q <= lcd_vs;

            if (!lcd_hs && hs_q) begin
                if (px_cnt != 0) hs_per = px_cnt;
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
                    // dut.y holds the row of the pixel that was just finished,
                    // which is exactly the pixel on lcd_r/g/b right now
                    if (dut.y >= 10'd48 && dut.y < 10'd96)
                        if (lcd_r > 5'd16) ramp_r_hi = ramp_r_hi + 1;

                    if (dut.y >= 10'd96 && dut.y < 10'd144)
                        if (lcd_g > 6'd32) ramp_g_hi = ramp_g_hi + 1;

                    if (dut.y >= 10'd144 && dut.y < 10'd192)
                        if (lcd_b > 5'd16) ramp_b_hi = ramp_b_hi + 1;

                    if (dut.y >= 10'd192 && dut.y < 10'd224) begin
                        if (lcd_r == 5'd31 && lcd_g == 6'd0 && lcd_b == 5'd0)
                            blk_red = blk_red + 1;
                        if (lcd_r == 5'd0 && lcd_g == 6'd63 && lcd_b == 5'd0)
                            blk_green = blk_green + 1;
                    end

                    if (dut.y < 10'd16)
                        if (lcd_r == 5'd31 && lcd_g == 6'd63 && lcd_b == 5'd31)
                            ruler_lit = ruler_lit + 1;

                    if (dut.y >= 10'd224)
                        if (lcd_g == 6'd63)
                            bars_lit = bars_lit + 1;
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

    task reset_counters;
        begin
            ramp_r_hi = 0;  ramp_g_hi = 0;  ramp_b_hi = 0;
            blk_red   = 0;  blk_green = 0;
            ruler_lit = 0;  bars_lit  = 0;
            counting  = 1'b0;
            arm       = 1'b1;
        end
    endtask

    // plain frame wait, used before anything is armed
    task wait_frames;
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

    task wait_one_frame;
        integer guard;
        begin
            guard = 0;
            while ((arm || counting) && guard < 8000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    integer bars_prev;

    //------------------------------------------------------------------
    // run
    //------------------------------------------------------------------
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_lcd_only.vcd");
            $dumpvars(0, tb_lcd_only);
        end

        rst_n = 1'b0;
        repeat (40) @(posedge clk27);
        rst_n = 1'b1;

        // let the PLL lock, the reset synchroniser release and the panel run
        // a few complete frames before anything is measured
        wait_frames(4);

        $display("");
        $display("---- timing ----");
        check_num("DCLK half period in sys clocks (9 MHz)", dclk_per, 6);
        check_num("HS period in pixels", hs_per, 525);
        check_num("VS period in lines",  vs_per, 286);
        check_num("lines with wrong DE count", bad_de, 0);

        $display("");
        $display("---- picture, frame A ----");
        reset_counters;
        wait_one_frame;
        $display("      ramp upper half  R=%0d G=%0d B=%0d",
                 ramp_r_hi, ramp_g_hi, ramp_b_hi);
        $display("      colour blocks red=%0d green=%0d   ruler=%0d   bars=%0d",
                 blk_red, blk_green, ruler_lit, bars_lit);

        check("red ramp fills the upper half of its band",
              ramp_r_hi >= 10800 && ramp_r_hi <= 10848);
        check("green ramp fills the upper half of its band",
              ramp_g_hi >= 10800 && ramp_g_hi <= 10848);
        check("blue ramp fills the upper half of its band",
              ramp_b_hi >= 10800 && ramp_b_hi <= 10848);
        check_num("red reference block is 30 x 32", blk_red, 960);
        check_num("green reference block is 30 x 32", blk_green, 960);
        check("one bright ruler block (30 x 16, plus the sweep)",
              ruler_lit >= 480 && ruler_lit <= 496);
        check("animated bars are drawn", bars_lit > 5000);

        bars_prev = bars_lit;

        $display("");
        $display("---- picture, frame B (animation must have moved) ----");
        reset_counters;
        wait_one_frame;
        $display("      bars=%0d  (previous frame %0d)", bars_lit, bars_prev);
        check("bar animation advances between frames", bars_lit != bars_prev);

        $display("");
        if (failures == 0)
            $display("== tb_lcd_only : ALL PASS (%0d checks) ==", chk);
        else
            $display("== tb_lcd_only : %0d FAILURE(S) of %0d ==", failures, chk);

        $finish;
    end

    initial begin
        #500000000;
        $display("== tb_lcd_only : TIMEOUT ==");
        $finish;
    end

endmodule
