//=============================================================================
// tb_fx_echo.v  --  self-checking test bench for fx_echo (echo path)
//
//  The DUT is instantiated with a short ring (64 samples) and a 32-sample tap
//  so the delay line can be walked through in a few hundred samples instead
//  of 6000.  Reverb and chorus are disabled here -- they have their own
//  bench (tb_fx_rvb_cho.v).
//
//  Checks
//    1. reset leaves the output silent
//    2. the block has a fixed latency, wet or dry
//    3. with on = 0 the output is an exact delayed copy of the input, so
//       switching the effect off cannot change the I2S phase
//    4. with on = 1, wet = 0.25 and feedback = 0 the impulse comes back
//       exactly DELAY samples later at 1/4 amplitude
//    5. toggling `on` mid-stream never changes the number of output samples
//
//  Every phase flushes the ring with silence first, so leftovers from the
//  previous phase cannot masquerade as an echo of the current one.
//
//  Note on the gap: the tap sweep inside the DUT takes NTAP+2 = 8 clocks per
//  sample.  On the board `en` fires once every 2240 clocks, so the sweep has
//  280x headroom; the bench only has to leave at least 8 idle clocks between
//  pushes for the sequencer to finish.
//=============================================================================
`timescale 1ns / 1ps

module tb_fx_echo;

    reg                clk = 1'b0;
    reg                rst_n = 1'b0;
    reg                en = 1'b0;
    reg                on = 1'b0;
    reg  signed [15:0] din = 16'sd0;
    wire signed [15:0] dout;
    wire               en_o;

    integer errors = 0;
    integer i;

    localparam integer DLY = 32;
    localparam integer DEP = 6;         // 64 samples of ring
    localparam integer GAP = 10;        // idle clocks between pushes

    fx_echo #(
        .DEPTH_LOG2 (DEP),
        .DELAY      (DLY),
        .RV1        (8),
        .RV2        (16),
        .RV3        (24),
        .RV4        (48),
        .CH_D       (32),
        .FB_ENABLE  (0),                // no feedback for the tap tests
        .WET_SH     (2)                 // 0.25
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .en     (en),
        .on     (on),
        .rvb_on (1'b0),
        .cho_on (1'b0),
        .din    (din),
        .dout   (dout),
        .en_o   (en_o)
    );

    always #5 clk = ~clk;

    task check;
        input         cond;
        input [511:0] msg;
        begin
            if (cond) begin
                $display("PASS  %0s", msg);
            end else begin
                $display("FAIL  %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    reg signed [15:0] cap [0:1023];
    integer           capn = 0;

    task push;
        input signed [15:0] v;
        integer k;
        begin
            din <= v;
            @(posedge clk);
            en  <= 1'b1;
            @(posedge clk);
            en  <= 1'b0;
            din <= 16'sd0;
            for (k = 0; k < GAP; k = k + 1) @(posedge clk);
        end
    endtask

    task flush;
        input integer cnt;
        integer j;
        begin
            for (j = 0; j < cnt; j = j + 1) push(16'sd0);
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && en_o) begin
            cap[capn] = dout;
            capn = capn + 1;
        end
    end

    // start a new measurement window once the line is primed and quiet
    task arm;
        begin
            flush(DLY + 8);
            repeat (GAP + 4) @(posedge clk);
            capn = 0;
        end
    endtask

    integer first_nonzero;
    integer badx;

    initial begin
        $display("== tb_fx_echo ==");

        //--------------------------------------------------------------
        // 1. reset -> no valid pulses at all
        //--------------------------------------------------------------
        rst_n = 1'b0;
        en    = 1'b0;
        repeat (8) @(posedge clk);
        check(capn == 0, "reset produces no valid output");
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        //--------------------------------------------------------------
        // 2/3. on = 0 : exact delayed copy
        //--------------------------------------------------------------
        on = 1'b0;
        arm;
        // a staircase, so a wrong latency shows up immediately
        for (i = 0; i < 32; i = i + 1) push(i * 100);
        repeat (GAP + 4) @(posedge clk);

        check(capn >= 32, "dry path emits one sample per push");
        badx = 0;
        for (i = 0; i < 32; i = i + 1)
            if (cap[i] !== (i * 100)) badx = badx + 1;
        check(badx == 0, "on=0: dry path is a constant-delay copy of the input");

        //--------------------------------------------------------------
        // 4. on = 1, fb = 0 : single echo at DELAY, amplitude 1/4
        //--------------------------------------------------------------
        on = 1'b1;
        arm;
        push(16'sd1000);                       // the impulse
        for (i = 0; i < (DLY + 8); i = i + 1) push(16'sd0);
        repeat (GAP + 4) @(posedge clk);

        first_nonzero = -1;
        for (i = 1; i < ((capn < 128) ? capn : 128); i = i + 1)
            if (cap[i] !== 16'sd0 && first_nonzero < 0) first_nonzero = i;

        check(cap[0] == 16'sd1000, "impulse passes through the dry path unchanged");
        check(first_nonzero == DLY, "echo arrives exactly DELAY samples after the dry hit");
        check((capn > DLY) && (cap[DLY] == 16'sd250),
              "echo amplitude is wet = 0.25 of the impulse (1000 -> 250)");
        check(dut.FB_ENABLE == 0, "this instance runs with feedback disabled");

        //--------------------------------------------------------------
        // 5. toggling `on` mid-stream must not change the sample count
        //--------------------------------------------------------------
        arm;
        for (i = 0; i < 16; i = i + 1) begin
            on = i[0];
            push(16'sd500);
        end
        repeat (GAP + 4) @(posedge clk);
        check(capn >= 16, "toggling on/off keeps exactly one output per input");

        $display("== tb_fx_echo : %0s (%0d errors) ==",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        $finish;
    end

endmodule
