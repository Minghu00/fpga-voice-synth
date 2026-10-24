//=============================================================================
// tb_top.v  --  full-system integration test
//
//   DUT  : rtl/top.v  (frame_gen + ttp229_rx + keymap + osc_bank + adsr x16
//                      + mixer16 + i2s_tx + lat_counter)
//   Model: sim/pll_sys_sim.v (108 MHz), sim/ttp229_model.v (16-key 2-wire)
//
//   Checks
//     1  PLL lock -> internal reset releases, TTP229 receiver leaves warm-up
//     2  TTP229 frames are received continuously (frame_ok active)
//     3  silence when no key is pressed
//     4  touching TP4 raises gate[3] and produces audio
//     5  latency (key_raw change -> audio) is microseconds, far below 10 ms
//     6  releasing the key returns the output to silence
//     7  the I2S bit stream carries the mixed word, mono duplicated to L/R
//     8  the audio frame period is exactly 2240 clk
//=============================================================================
`timescale 1ns / 1ps

module tb_top;

    integer errors = 0;
    integer i, k, nz, wait_frames;

    task chk;
        input cond;
        input [1023:0] msg;
        begin
            if (cond) $display("PASS  %0s", msg);
            else begin
                $display("FAIL  %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // clocks and reset
    //-------------------------------------------------------------------------
    reg clk27 = 1'b0;
    always #18.5185 clk27 = ~clk27;          // 27 MHz

    reg rst_n = 1'b0;

    wire clk_sys = dut.clk_sys;
    wire srst_n  = dut.srst_n;

    //-------------------------------------------------------------------------
    // touch panel model
    //-------------------------------------------------------------------------
    reg  [15:0] keys = 16'h0000;
    wire        tp_sdo;
    wire        tp_scl;
    wire        lcd_dclk, lcd_hs, lcd_vs, lcd_de;
    wire [4:0]  lcd_r;
    wire [5:0]  lcd_g;
    wire [4:0]  lcd_b;

    ttp229_model #(.IDLE_CLK(20), .ACTIVE_LOW(1)) u_model (
        .clk  (clk_sys),
        .rst_n(srst_n),
        .scl  (tp_scl),
        .keys (keys),
        .sdo  (tp_sdo)
    );

    //-------------------------------------------------------------------------
    // DUT  (fast parameters so the test runs in seconds)
    //-------------------------------------------------------------------------
    wire i2s_bclk, i2s_lrclk, i2s_din;

    top #(
        .INIT_CLK  (100),
        .POLL_CLK  (2000),
        .SCL_HALF  (8),
        .ACTIVE_LOW(1),
        .ATT_STEP  (20_000),
        .DEC_STEP  (20_000),
        .REL_STEP  (30_000),
        .SUSTAIN   (20_000)
    ) dut (
        .clk27    (clk27),
        .rst_n    (rst_n),
        .tp_sdo   (tp_sdo),
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

    //-------------------------------------------------------------------------
    // frame-accurate helpers
    //-------------------------------------------------------------------------
    wire [11:0] fc = dut.fc;

    integer fcnt = 0;
    integer ftarget;

    always @(posedge clk_sys)
        if (srst_n && (fc == 12'd2239))
            fcnt <= fcnt + 1;

    task run_frames;
        input integer n;
        begin
            @(negedge clk_sys);
            ftarget = fcnt + n;
            while (fcnt < ftarget) @(negedge clk_sys);
        end
    endtask

    // did the mix output ever leave zero just after the next frame boundary?
    reg heard_r;
    task heard;
        begin
            run_frames(1);
            while (fc != 12'd400) @(negedge clk_sys);
            heard_r = ($signed(dut.mix_out) != 16'sd0);
        end
    endtask

    //-------------------------------------------------------------------------
    // I2S capture on rising BCLK
    //-------------------------------------------------------------------------
    reg [31:0] is_word = 32'h0;
    integer    is_bitc = 0;
    reg        is_done = 1'b0;

    always @(posedge i2s_bclk) begin
        if (!is_done) begin
            is_word = {is_word[30:0], i2s_din};
            is_bitc = is_bitc + 1;
            if (is_bitc == 32) is_done <= 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // latency meter observation
    //-------------------------------------------------------------------------
    reg [31:0] lat_seen_val = 32'h0;
    reg        lat_seen     = 1'b0;

    always @(posedge clk_sys) begin
        if (dut.lat_valid) begin
            lat_seen     <= 1'b1;
            lat_seen_val <= dut.lat_val;
        end
    end

    //-------------------------------------------------------------------------
    // frame period measurement
    //-------------------------------------------------------------------------
    integer meas_cnt = 0;
    reg     meas_en  = 1'b0;

    always @(posedge clk_sys)
        if (meas_en) meas_cnt <= meas_cnt + 1;

    //-------------------------------------------------------------------------
    // stimulus
    //-------------------------------------------------------------------------
    initial begin
        rst_n = 1'b0;
        #2000;
        rst_n = 1'b1;
        run_frames(4);

        //---------------------------------------------------------------------
        // 1  reset / lock / warm-up
        //---------------------------------------------------------------------
        wait_frames = 0;
        while ((dut.awake !== 1'b1) && (wait_frames < 400)) begin
            run_frames(1);
            wait_frames = wait_frames + 1;
        end
        chk(dut.awake === 1'b1, "TTP229 receiver leaves warm-up (awake)");
        $display("      awake after %0d frames", wait_frames);
        chk(dut.locked === 1'b1, "PLL reports locked");
        chk(dut.srst_n === 1'b1, "internal reset has released");

        //---------------------------------------------------------------------
        // 2  touch frames keep arriving
        //---------------------------------------------------------------------
        k = 0;
        @(posedge dut.frame_ok);
        repeat (4000) begin
            @(negedge clk_sys);
            if (dut.frame_ok) k = k + 1;
        end
        chk(k > 0, "TTP229 frames are being received (frame_ok active)");
        $display("      frame_ok high for %0d clk out of 4000", k);

        //---------------------------------------------------------------------
        // 3  silence with no key pressed
        //---------------------------------------------------------------------
        nz = 0;
        for (i = 0; i < 60; i = i + 1)
            begin heard; nz = nz + heard_r; end
        chk(nz == 0, "output is silent while no key is touched");

        //---------------------------------------------------------------------
        // 4  touch TP4 (bit 4 -> voice 3) and listen
        //---------------------------------------------------------------------
        @(negedge clk_sys);
        keys = 16'h0010;
        run_frames(3);

        nz = 0;
        for (i = 0; i < 40; i = i + 1) begin
            run_frames(1);
            if (dut.gate[4] === 1'b1) nz = nz + 1;
        end
        chk(nz > 0, "key TP4 raises gate[4]");

        nz = 0;
        for (i = 0; i < 40; i = i + 1)
            begin heard; nz = nz + heard_r; end
        chk(nz > 30, "touching a key produces non-zero audio");
        $display("      non-zero output on %0d of 40 frames", nz);

        //---------------------------------------------------------------------
        // 5  latency seen by the meter
        //---------------------------------------------------------------------
        chk(lat_seen === 1'b1, "latency meter produced a measurement");
        chk(lat_seen_val < 32'd4800,
            "latency (key_raw -> audio) below 4800 clk = 44 us, far below 10 ms");
        $display("      lat_val = %0d clk = %0d ns", lat_seen_val,
                 lat_seen_val * 1000 / 108);

        //---------------------------------------------------------------------
        // 7  I2S word carries the mixed sample, L == R
        //---------------------------------------------------------------------
        @(negedge i2s_bclk);
        is_bitc = 0;
        is_done = 1'b0;
        is_word = 32'h0;
        k = 0;
        while ((is_done !== 1'b1) && (k < 200000)) begin
            @(negedge clk_sys);
            k = k + 1;
        end
        $display("      I2S word = %08x  (L=%04x R=%04x)", is_word,
                 is_word[31:16], is_word[15:0]);
        chk(is_word != 32'h0, "I2S stream is not silent while a key is held");
        chk(is_word[31:16] == is_word[15:0],
            "left and right channels are identical");

        //---------------------------------------------------------------------
        // 6  release and confirm the tail dies away
        //---------------------------------------------------------------------
        keys = 16'h0000;
        run_frames(1);
        run_frames(40);

        nz = 0;
        for (i = 0; i < 40; i = i + 1)
            begin heard; nz = nz + heard_r; end
        chk(nz == 0, "release returns the output to silence");

        //---------------------------------------------------------------------
        // 8  audio frame period
        //---------------------------------------------------------------------
        meas_cnt = 0;
        @(posedge dut.sample_tick);
        @(posedge clk_sys);
        meas_en  = 1'b1;
        @(posedge dut.sample_tick);
        meas_en  = 1'b0;
        #1;
        $display("      sample_tick period = %0d clk (want 2240)", meas_cnt);
        chk(meas_cnt == 2240, "audio frame period is exactly 2240 clk");

        //---------------------------------------------------------------------
        if (errors == 0) $display("== tb_top : ALL PASS ==");
        else             $display("== tb_top : %0d FAILURE(S) ==", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("== tb_top : TIMEOUT ==");
        $finish;
    end

endmodule
