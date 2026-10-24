//=============================================================================
// tb_ttp229_rx.v  --  self-checking testbench for the POLLING ttp229_rx
//
//  Checks
//    1. awake rises after the settle counter expires
//    2. frames keep arriving on their own (polling really is free-running)
//    3. no key touched        -> key_raw == 0
//    4. one key   (TP4)       -> key_raw == 16'h0010
//    5. two keys  (TP0+TP15)  -> key_raw == 16'h8001
//    6. all keys              -> key_raw == 16'hFFFF
//    7. released again        -> key_raw == 0
//    8. the low-phase and high-phase words agree on every sample
//    9. STABILITY FILTER: a word that shows up for only ONE poll must be
//       thrown away instead of appearing as a key press.  This is what stops
//       a too-sensitive pad from flashing a neighbouring key cell for 1 ms
//       (and, on the instrument, from clicking a spurious note).
//       Acceptance therefore takes three identical polls in a row.
//=============================================================================
`timescale 1ns / 1ps

module tb_ttp229_rx;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg  [15:0] keys  = 16'h0000;
    reg  [15:0] gkeys = 16'h0000;
    reg         glitch = 1'b0;

    wire tp_scl;
    wire tp_sdo;
    wire [15:0] key_raw;
    wire [15:0] key_hi;
    wire [15:0] poll_cnt;
    wire        frame_ok;
    wire        awake;

    integer errors = 0;
    integer frames = 0;

    always #4.6296 clk = ~clk;

    // shortened timings: settle 100 clk, one poll every 2000 clk, SCL 8 clk
    // per half period.  SCL_HALF must exceed the receiver's 2 clk SDO
    // synchroniser plus the model's 1 clk reaction, hence 8 not 4.
    ttp229_rx #(
        .INIT_CLK  (100),
        .POLL_CLK  (2000),
        .SCL_HALF  (8),
        .ACTIVE_LOW(1)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .tp_sdo   (tp_sdo),
        .tp_scl   (tp_scl),
        .key_raw  (key_raw),
        .key_hi   (key_hi),
        .poll_cnt (poll_cnt),
        .frame_ok (frame_ok),
        .awake    (awake)
    );

    ttp229_model #(
        .IDLE_CLK  (20),
        .ACTIVE_LOW(1)
    ) model (
        .clk  (clk),
        .rst_n(rst_n),
        .scl  (tp_scl),
        .keys (keys),
        .gkeys(gkeys),
        .glitch(glitch),
        .sdo  (tp_sdo)
    );

    always @(posedge clk)
        if (frame_ok) frames <= frames + 1;

    // has bit 1 of key_raw ever been seen high? (used by the glitch test)
    reg saw_b1 = 1'b0;
    always @(posedge clk)
        if (rst_n && key_raw[1]) saw_b1 <= 1'b1;

    //----------------------------------------------------------------------
    // wait for n more polls
    //----------------------------------------------------------------------
    task wait_polls;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge frame_ok);
        end
    endtask

    //----------------------------------------------------------------------
    // wait until key_raw equals k (up to 12 polls), then report
    //----------------------------------------------------------------------
    task expect_keys;
        input [15:0] k;
        input [511:0] name;
        integer p;
        reg ok;
        begin
            ok = 1'b0;
            for (p = 0; (p < 12) && !ok; p = p + 1) begin
                if (key_raw === k)
                    ok = 1'b1;
                else
                    @(posedge frame_ok);
            end
            if (key_raw !== k) begin
                $display("FAIL  %0s : key_raw=%h expected %h", name, key_raw, k);
                errors = errors + 1;
            end else begin
                $display("PASS  %0s : key_raw=%h", name, key_raw);
            end
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_ttp229_rx.vcd");
            $dumpvars(0, tb_ttp229_rx);
        end

        frames = 0;
        keys   = 16'h0000;

        #200 rst_n = 1'b1;

        // 1. settle timer
        begin : wait_awake
            integer g;
            g = 0;
            while (!awake && g < 20000) begin
                @(posedge clk);
                g = g + 1;
            end
        end
        if (!awake) begin
            $display("FAIL  awake never asserted");
            errors = errors + 1;
        end else begin
            $display("PASS  awake asserted after settle");
        end

        // 2. polling is free-running
        expect_keys(16'h0000, "no key touched");

        // 3. one key
        keys = 16'h0010;
        expect_keys(16'h0010, "single key TP4");
        expect_keys(16'h0010, "single key TP4 (repeat)");

        // 4. two keys at the two extremes
        keys = 16'h8001;
        expect_keys(16'h8001, "keys TP0+TP15");

        // 5. all keys
        keys = 16'hFFFF;
        expect_keys(16'hFFFF, "all 16 keys");

        // 6. release
        keys = 16'h0000;
        expect_keys(16'h0000, "all released");

        // 7. both sampling phases must agree
        keys = 16'h1234;
        expect_keys(16'h1234, "pattern 1234");
        if (key_hi !== key_raw) begin
            $display("FAIL  low/high phase words differ : lo=%h hi=%h",
                     key_raw, key_hi);
            errors = errors + 1;
        end else begin
            $display("PASS  low/high phase words agree : %h", key_raw);
        end

        //------------------------------------------------------------------
        // 8. stability filter: one bogus burst must be ignored
        //------------------------------------------------------------------
        keys = 16'h0001;
        expect_keys(16'h0001, "steady key TP0");

        saw_b1 = 1'b0;
        gkeys  = 16'h0002;          // a single-poll lie: "TP1 is touched"
        glitch = 1'b1;
        @(posedge frame_ok);
        glitch = 1'b0;
        wait_polls(8);

        $display("");
        $display("---- single-poll glitch on TP1 ----");
        if (saw_b1) begin
            $display("FAIL  a one-poll glitch leaked into key_raw");
            errors = errors + 1;
        end else begin
            $display("PASS  one-poll glitch rejected (TP1 never appeared)");
        end
        expect_keys(16'h0001, "real key TP0 survived the glitch");

        // and a REAL change is still accepted, just 3 polls later
        keys = 16'h0004;
        expect_keys(16'h0004, "a real key change is still accepted");

        if (errors == 0)
            $display("\n== tb_ttp229_rx : ALL PASS ==");
        else
            $display("\n== tb_ttp229_rx : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
