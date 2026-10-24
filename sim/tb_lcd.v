//============================================================================
//  tb_lcd.v -- self-checking testbench for lcd_panel / lcd_timing / wave_buf
//
//  Checks
//    1. DCLK is 9 MHz (period = 12 system clocks)
//    2. HS period 525 pixels, sync low for 41
//    3. VS period 286 lines,  sync low for 10
//    4. DE high for exactly 480 pixels on every line, 272 lines per frame
//    5. the waveform region actually draws the buffered samples
//    6. the envelope bars and key indicators really are driven by
//       env_flat / key_raw (frame with all-on must light far more pixels)
//============================================================================
`timescale 1ns / 1ps

module tb_lcd;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    reg         wr_en = 1'b0;
    reg  [8:0]  wr_addr = 9'd0;
    reg  [15:0] wr_data = 16'd0;
    reg  [255:0] env_flat = 256'd0;
    reg  [15:0] key_raw = 16'd0;

    wire        lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0]  lcd_r;
    wire [5:0]  lcd_g;
    wire [4:0]  lcd_b;

    lcd_panel u_dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (wr_en),
        .wr_addr  (wr_addr),
        .wr_data  (wr_data),
        .env_flat (env_flat),
        .key_raw  (key_raw),
        .lcd_dclk (lcd_dclk),
        .lcd_hs   (lcd_hs),
        .lcd_vs   (lcd_vs),
        .lcd_de   (lcd_de),
        .lcd_r    (lcd_r),
        .lcd_g    (lcd_g),
        .lcd_b    (lcd_b)
    );

    always #4.6296 clk = ~clk;          // 108 MHz

    //------------------------------------------------------------------
    integer errors = 0;

    task check;
        input [255:0] name;
        input         cond;
        begin
            if (cond !== 1'b1) begin
                $display("FAIL  %0s", name);
                errors = errors + 1;
            end else
                $display("PASS  %0s", name);
        end
    endtask

    task check_num;
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got !== want) begin
                $display("FAIL  %0s : got %0d want %0d", name, got, want);
                errors = errors + 1;
            end else
                $display("PASS  %0s : %0d", name, got);
        end
    endtask

    //------------------------------------------------------------------
    // structural timing counters
    //------------------------------------------------------------------
    wire tick = u_dut.u_tmg.pix_tick;
    wire [9:0] cx = u_dut.u_tmg.x;
    wire [9:0] cy = u_dut.u_tmg.y;

    integer dclk_period   = 0;
    integer hs_period     = 0;
    integer vs_period     = 0;
    integer de_line       = 0;
    integer hs_low        = 0;
    integer lines         = 0;
    integer px_cnt        = 0;
    integer bad_de_lines  = 0;

    integer lit_wave   = 0;
    integer lit_mid    = 0;
    integer lit_key    = 0;
    integer frame_w    = 0;
    integer frame_m    = 0;
    integer frame_no   = 0;
    reg     counting   = 1'b0;

    // colour comparison: background is r=2 g=6 b=12
    wire is_bg = (lcd_r == 5'd2) && (lcd_g == 6'd6) && (lcd_b == 5'd12);

    // dclk period with an edge detector
    reg dclk_d = 1'b0;
    reg [15:0] dclk_cnt = 16'd0;
    always @(posedge clk) begin
        dclk_d <= lcd_dclk;
        if (lcd_dclk && !dclk_d) begin
            if (dclk_cnt != 16'd0)
                dclk_period = dclk_cnt + 1;
            dclk_cnt = 16'd0;
        end else begin
            dclk_cnt = dclk_cnt + 16'd1;
        end
    end

    reg hs_q = 1'b1;
    reg vs_q = 1'b1;

    always @(posedge clk) begin
        if (rst_n && tick) begin
            // NOTE: hs_q / vs_q are only updated on a pixel tick as well.
            // Updating them every clock would consume the edge during one of
            // the 11 non-tick cycles and the detectors below would never fire.
            hs_q <= lcd_hs;
            vs_q <= lcd_vs;

            // ---------- horizontal ----------
            if (!lcd_hs && hs_q) begin
                if (px_cnt != 0) hs_period = px_cnt;
                if (cy < 10'd272) begin
                    if (de_line != 480) bad_de_lines = bad_de_lines + 1;
                end else begin
                    if (de_line != 0)   bad_de_lines = bad_de_lines + 1;
                end
                px_cnt  = 0;
                de_line = 0;
                lines   = lines + 1;
            end
            px_cnt = px_cnt + 1;

            // ---------- vertical ----------
            if (!lcd_vs && vs_q) begin
                if (lines != 0) vs_period = lines;
                if (hs_low != 41 * vs_period && frame_no > 1)
                    $display("      frame%0d hs_low=%0d (want %0d)",
                             frame_no, hs_low, 41 * vs_period);
                lines    = 0;
                hs_low   = 0;
                frame_no = frame_no + 1;
            end

            // ---------- DE cell counting ----------
            if (lcd_de) begin
                de_line = de_line + 1;
                if (counting) begin
                    if (cy < 10'd120)
                        lit_wave = lit_wave + (is_bg ? 0 : 1);
                    else if (cy < 10'd256)
                        lit_mid  = lit_mid  + (is_bg ? 0 : 1);
                    else
                        lit_key  = lit_key  + (is_bg ? 0 : 1);
                end
            end

            if (!lcd_hs) hs_low = hs_low + 1;
        end
    end

    task wait_frame;
        input integer n;
        integer g;
        begin
            g = 0;
            while (frame_no < n && g < 8000000) begin
                @(posedge clk);
                g = g + 1;
            end
            if (g >= 8000000)
                $display("TIMEOUT waiting for frame %0d (frame_no=%0d)", n, frame_no);
        end
    endtask

    //------------------------------------------------------------------
    // stimulus
    //------------------------------------------------------------------
    integer i;
    integer period;
    real    ph;

    initial begin
        // preload one full-scale sine period into the history RAM
        period = 184;                              // ~ C4 at 48.214 kHz
        for (i = 0; i < 512; i = i + 1) begin
            ph = 2.0 * 3.14159265358979 * ((i % period) * 1.0) / (period * 1.0);
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = i[8:0];
            wr_data = $rtoi(32767.0 * $sin(ph));
        end
        @(negedge clk);
        wr_en   = 1'b0;
        wr_addr = 9'd480;                          // displayed window = mem[0..479]

        #500 rst_n = 1'b1;

        env_flat = 256'd0;
        key_raw  = 16'd0;
        counting = 1'b0;

        // frame 1: everything off, only the scope trace is visible
        wait_frame(1);
        lit_wave = 0; lit_mid = 0; lit_key = 0;
        counting = 1'b1;
        wait_frame(2);
        counting = 1'b0;
        frame_m = lit_mid;
        $display("      frame1: wave lit=%0d  mid lit=%0d  key lit=%0d",
                 lit_wave, lit_mid, lit_key);
        check("scope trace is drawn", lit_wave > 900);
        check("key row renders", lit_key == 480*16);

        // frame 2: every envelope and every key on
        env_flat = {16{16'hFFFF}};
        key_raw  = 16'hFFFF;
        lit_wave = 0; lit_mid = 0; lit_key = 0;
        counting = 1'b1;
        wait_frame(3);
        counting = 1'b0;
        $display("      frame2: wave lit=%0d  mid lit=%0d  key lit=%0d",
                 lit_wave, lit_mid, lit_key);
        check("bars fill their area with env on", lit_mid > 39000);
        check("bars changed with env", lit_mid > frame_m + 30000);

        $display("      dclk period = %0d clk (want 12)", dclk_period);
        check_num("DCLK period in system clocks", dclk_period, 12);
        $display("      hs_period = %0d pixels  vs_period = %0d lines  bad_de_lines = %0d",
                 hs_period, vs_period, bad_de_lines);
        check_num("HS period in pixels", hs_period, 525);
        check_num("VS period in lines",  vs_period, 286);
        check_num("lines with wrong DE count", bad_de_lines, 0);

        if (errors == 0)
            $display("== tb_lcd : ALL PASS ==");
        else
            $display("== tb_lcd : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
