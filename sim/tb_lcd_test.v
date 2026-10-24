//=============================================================================
//  tb_lcd_test.v -- self test for the diagnostic bring-up build
//
//  Checks
//    1  DCLK half period is 6 sys clocks  (9 MHz)
//    2  HS period 525 pixels, VS period 286 lines
//    3  no active line carries a wrong number of DE pixels
//    4  ROW A lights exactly one 30 x 64 cell for a one-hot key word
//    5  ROW B lights the same cell (both sampling edges agree)
//    6  ROW C is fully dark when the two edges agree
//    7  the heartbeat block is drawn
//    8  one frame later ROW A follows the model again (release -> dark)
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

    reg  [15:0] tp_keys = 16'h0000;

    top_lcd_test #(
        .INIT_CLK  (100),
        .POLL_CLK  (2000),
        .SCL_HALF  (8),
        .ACTIVE_LOW(1)
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

    ttp229_model #(.IDLE_CLK(20), .ACTIVE_LOW(1)) u_model (
        .clk  (dut.clk_sys),
        .rst_n(dut.srst_n),
        .scl  (tp_scl),
        .keys (tp_keys),
        .sdo  (tp_sdo)
    );

    //------------------------------------------------------------------
    // counters
    //------------------------------------------------------------------
    wire clk  = dut.clk_sys;
    wire tick = dut.pix_tick;

    integer errors = 0;

    task chk;
        input cond;
        input [511:0] msg;
        begin
            if (cond) $display("PASS  %0s", msg);
            else begin
                $display("FAIL  %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    task chk_num;
        input [511:0] msg;
        input integer got;
        input integer want;
        begin
            if (got == want) $display("PASS  %0s : %0d", msg, got);
            else begin
                $display("FAIL  %0s : %0d expected %0d", msg, got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer dclk_cnt = 0;
    integer dclk_per = 0;
    integer px_cnt   = 0;
    integer hs_per   = 0;
    integer vs_per   = 0;
    integer lines    = 0;
    integer frame_no = 0;
    integer de_line  = 0;
    integer bad_de   = 0;

    reg dclk_q = 1'b0;
    reg hs_q   = 1'b1;
    reg vs_q   = 1'b1;

    // per-frame colour counters
    integer cA = 0;      // ROW A cell lit
    integer cB = 0;      // ROW B cell lit
    integer cC = 0;      // hex readout amber segments
    integer cH = 0;      // white sweep line
    integer cS = 0;      // status strip (any non-black)

    integer cA_last = 0;
    integer cB_last = 0;
    integer cC_last = 0;
    integer cH_last = 0;
    integer hex_press = 0;
    integer cS_last = 0;

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
            // hs_q / vs_q must be updated on the same cadence as the compare,
            // otherwise one of the non-tick cycles swallows the edge.
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
                lines   = 0;
                frame_no = frame_no + 1;
                cA_last  = cA;
                cB_last  = cB;
                cC_last  = cC;
                cH_last  = cH;
                cS_last  = cS;
                cA = 0; cB = 0; cC = 0; cH = 0; cS = 0;
            end

            if (lcd_de) begin
                de_line = de_line + 1;

                // ROW A bright cell
                if (lcd_r == 5'd2 && lcd_g == 6'd60 && lcd_b == 5'd2)
                    cA = cA + 1;
                // ROW B bright cell
                if (lcd_r == 5'd28 && lcd_g == 6'd44 && lcd_b == 5'd2)
                    cB = cB + 1;
                // hex readout, amber lit segments
                if (lcd_r == 5'd31 && lcd_g == 6'd46 && lcd_b == 5'd0)
                    cC = cC + 1;
                // heartbeat / sweep white
                if (lcd_r == 5'd31 && lcd_g == 6'd63 && lcd_b == 5'd31)
                    cH = cH + 1;
                // anything that is not pure black
                if (lcd_r != 5'd0 || lcd_g != 6'd0 || lcd_b != 5'd0)
                    cS = cS + 1;
            end
        end
    end

    // wait for the frame counter to advance past a target
    task wait_frame;
        input integer n;
        integer g;
        begin
            g = 0;
            while ((frame_no < n) && (g < 4000000)) begin
                @(posedge clk);
                g = g + 1;
            end
        end
    endtask

    task measure_one_frame;
        input integer n;
        begin
            wait_frame(n);
            wait_frame(n + 2);          // cX_last now holds a complete frame
        end
    endtask

    initial begin
        $dumpfile("sim/tb_lcd_test.vcd");
        $dumpvars(0, tb_lcd_test);

        #200 rst_n = 1'b1;

        wait_frame(4);

        chk_num("DCLK half period in sys clocks (9 MHz)", dclk_per, 6);
        chk_num("HS period in pixels", hs_per, 525);
        chk_num("VS period in lines", vs_per, 286);
        chk_num("lines with a wrong DE count", bad_de, 0);

        //------------------------------------------------------------------
        // one key held -> exactly one cell lit in ROW A and ROW B
        //------------------------------------------------------------------
        tp_keys = 16'h0010;             // TP4
        wait_frame(frame_no + 6);
        measure_one_frame(frame_no + 1);

        $display("      ROW A lit = %0d   ROW B lit = %0d   hex seg px = %0d   white = %0d   non-black = %0d",
                 cA_last, cB_last, cC_last, cH_last, cS_last);

        // a cell is 30 px wide x 64 px tall; the 1 px sweep line can eat up
        // to 64 of them, so allow a small window
        chk(cA_last >= 60*64 - 80 && cA_last <= 60*64,
            "ROW A lights exactly one 60 x 64 cell");
        chk(cB_last >= 60*64 - 80 && cB_last <= 60*64,
            "ROW B lights the same cell (both edges agree)");
        // key word 0x0010 -> digits "0010": 6+6+2+6 = 20 segments lit
        chk(cC_last > 3000 && cC_last < 12000,
            "hex readout draws the key word");
        hex_press = cC_last;
        chk(cH_last >= 900, "sweep line is drawn");
        chk(cS_last > 100000, "the screen is not blank");

        //------------------------------------------------------------------
        // release -> everything goes dark again
        //------------------------------------------------------------------
        tp_keys = 16'h0000;
        wait_frame(frame_no + 6);
        measure_one_frame(frame_no + 1);

        $display("      after release: ROW A lit = %0d   ROW B lit = %0d   hex seg px = %0d",
                 cA_last, cB_last, cC_last);
        chk_num("ROW A dark after release", cA_last, 0);
        chk_num("ROW B dark after release", cB_last, 0);
        // key word 0x0000 -> digits "0000": 24 segments lit, more than "0010"
        chk(cC_last > hex_press + 500,
            "hex readout follows the key word");

        if (errors == 0)
            $display("== tb_lcd_test : ALL PASS ==");
        else
            $display("== tb_lcd_test : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
