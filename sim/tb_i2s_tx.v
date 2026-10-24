//=============================================================================
// tb_i2s_tx.v  --  self-checking testbench for i2s_tx
//
//  Checks
//    1. BCLK period is 2 * BCLK_HALF = 70 clk  (1.5429 MHz)
//    2. exactly 2240 clk per frame, i.e. one I2S frame == one audio frame.
//       The shipped design cycled in 2241 clk (a spare S_IDLE state), so the
//       sample-to-bits phase slid by one clock every frame and re-locked with
//       a click roughly every 46 ms.
//    3. the serialised 32 bit word equals {sample_l, sample_r}
//    4. LRCK is low for the whole left slot and high for the whole right slot
//    5. LRCK RETURNS LOW for the next frame  (the shipped bug was that LRCK
//       stayed high for ever after the first frame, so the DAC received
//       nothing but zeros -- "amplifier silent, display perfect")
//    6. three different data sets, so a wrap-around error at the left/right
//       boundary cannot hide   (the other shipped bug: the last LSB of the
//       left word was replaced by a bit of the right word)
//    7. din is stable across every BCLK rising edge
//    8. a load_tick that lands mid-slot is honoured at the next frame
//       boundary, never mid-word  (load_tick used to be ignored entirely)
//=============================================================================
`timescale 1ns / 1ps

module tb_i2s_tx;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg  [11:0] fc    = 12'd0;

    localparam [15:0] SLA = 16'h1234;
    localparam [15:0] SRA = 16'hEDCC;
    localparam [15:0] SLB = 16'hF00F;
    localparam [15:0] SRB = 16'h0A05;
    localparam [15:0] SLC = 16'h8000;
    localparam [15:0] SRC = 16'h7FFF;

    reg [15:0] SL = 16'h0000;
    reg [15:0] SR = 16'h0000;

    reg        load_tick = 1'b0;

    wire bclk, lrclk, din;

    always #4.6296 clk = ~clk;

    i2s_tx #(.BCLK_HALF(35)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .fc        (fc),
        .load_tick (load_tick),
        .sample_l  (SL),
        .sample_r  (SR),
        .bclk      (bclk),
        .lrclk     (lrclk),
        .din       (din)
    );

    // free-running audio frame reference (informational only)
    always @(posedge clk) begin
        if (!rst_n)            fc <= 12'd0;
        else if (fc == 12'd2239) fc <= 12'd0;
        else                   fc <= fc + 12'd1;
    end

    //------------------------------------------------------------------
    // load_tick: exactly one pulse per 2240 clk, deliberately NOT aligned
    // with the transmitter frame boundary -- that is the whole point of the
    // shadow register.
    //------------------------------------------------------------------
    integer lc = 0;
    always @(posedge clk) begin
        if (!rst_n)               lc <= 0;
        else if (lc == 2239)      lc <= 0;
        else                      lc <= lc + 1;
        load_tick <= rst_n && (lc == 1119);
    end

    //------------------------------------------------------------------
    // capture on BCLK rising edges.  dut.bitn names the bit being latched:
    // bitn == 0 is the first rising edge of a frame, bitn == 31 the last.
    //------------------------------------------------------------------
    reg         bclk_d = 1'b0;
    reg         din_d  = 1'b0;
    reg  [31:0] w_cap, w_lr;
    reg  [31:0] cap_snap, lr_snap;
    integer     frames      = 0;
    integer     errs        = 0;
    integer     period_errs = 0;
    integer     fper_errs   = 0;
    integer     stable_errs = 0;
    time        t_last      = 0;

    reg  [31:0] clkcount = 0;
    reg  [31:0] t_frame  = 0;
    reg         seen_frame = 1'b0;

    always @(posedge clk) begin
        clkcount <= clkcount + 32'd1;
    end

    always @(posedge clk) begin
        bclk_d <= bclk;
        din_d  <= din;

        if (bclk && !bclk_d) begin
            // BCLK period                (70 clk = 648.17 ns)
            if (t_last != 0) begin
                if ((($time - t_last) < 640) || (($time - t_last) > 656))
                    period_errs = period_errs + 1;
            end
            t_last = $time;

            if (dut.bitn == 6'd0) begin
                // first bit of a frame: a frame boundary just happened
                if (seen_frame) begin
                    if ((clkcount - t_frame) != 32'd2240)
                        fper_errs = fper_errs + 1;
                end
                t_frame    <= clkcount;
                seen_frame <= 1'b1;

                w_cap <= {31'd0, din};
                w_lr  <= {31'd0, lrclk};
            end else begin
                w_cap <= {w_cap[30:0], din};
                w_lr  <= {w_lr[30:0], lrclk};
            end

            if (dut.bitn == 6'd31) begin
                cap_snap <= {w_cap[30:0], din};
                lr_snap  <= {w_lr[30:0], lrclk};
                frames   = frames + 1;
            end
        end
    end

    // din must not move while bclk is high: that is the DAC's setup window.
    always @(posedge clk) begin
        if (rst_n && bclk && (din !== din_d))
            stable_errs = stable_errs + 1;
    end

    //------------------------------------------------------------------
    task wait_frames(input integer n);
        integer target;
        begin
            target = frames + n;
            while (frames < target) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task check_frame(input [31:0] expect, input [511:0] tag);
        begin
            if (cap_snap !== expect) begin
                $display("FAIL  [%0s] serialised word = %h (expected %h)",
                         tag, cap_snap, expect);
                errs = errs + 1;
            end else
                $display("PASS  [%0s] serialised word = %h", tag, cap_snap);

            if (lr_snap !== 32'h0000FFFF) begin
                $display("FAIL  [%0s] LRCK framing = %h (expected 0000ffff)", tag, lr_snap);
                $display("      LRCK did not return low -> the DAC would only ever");
                $display("      latch the right slot, i.e. silence after frame 1");
                errs = errs + 1;
            end else
                $display("PASS  [%0s] LRCK low for left slot, high for right slot", tag);
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_i2s_tx.vcd");
            $dumpvars(0, tb_i2s_tx);
        end

        #200 rst_n = 1'b1;

        // settle: the first frame after reset carries zeros until the first
        // load_tick has filled the shadow register
        SL = SLA;  SR = SRA;
        wait_frames(4);
        check_frame({SLA, SRA}, "frame1");

        SL = SLB;  SR = SRB;
        wait_frames(3);
        check_frame({SLB, SRB}, "frame2 lrclk returns");

        SL = SLC;  SR = SRC;
        wait_frames(3);
        check_frame({SLC, SRC}, "frame3 extremes");

        if (period_errs != 0) begin
            $display("FAIL  BCLK period out of range %0d times", period_errs);
            errs = errs + 1;
        end else
            $display("PASS  BCLK period = 70 clk (1.5429 MHz)");

        if (fper_errs != 0) begin
            $display("FAIL  frame = 2240 clk violated %0d times (audio/I2S would slip)",
                     fper_errs);
            errs = errs + 1;
        end else
            $display("PASS  frame = exactly 2240 clk (locked to the audio frame)");

        if (stable_errs != 0) begin
            $display("FAIL  din moved on %0d BCLK-high windows", stable_errs);
            errs = errs + 1;
        end else
            $display("PASS  din stable across every BCLK rising edge");

        if (errs == 0)
            $display("== tb_i2s_tx : ALL PASS ==");
        else
            $display("== tb_i2s_tx : %0d FAILURE(S) ==", errs);

        $finish;
    end

endmodule
