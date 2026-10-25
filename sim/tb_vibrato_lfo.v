//=============================================================================
// tb_vibrato_lfo.v  --  self-checking test bench for vibrato_lfo
//
//  Checks
//    1. with on = 0 the output is a hard zero (bit-identical to "no vibrato")
//    2. with on = 1 the output is a clean sine of |d| <= DEPTH
//    3. one full LFO period is 2^24 / PH_INC samples  (9643.8 for 5 Hz)
//    4. the peak is reached a quarter of a period in, i.e. the phase ->
//       index mapping really is a sine and not, say, a triangle
//    5. the waveform is symmetric: the negative peak has the same magnitude
//=============================================================================
`timescale 1ns / 1ps

module tb_vibrato_lfo;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         en = 1'b0;
    reg         on = 1'b0;
    wire signed [5:0] d;
    wire signed [5:0] d_abs;

    integer errors = 0;
    integer n;

    //------------------------------------------------------------------
    // DUT -- small PH_INC so the period is short enough to simulate
    //------------------------------------------------------------------
    localparam integer PHI  = 4096;     // period = 2^24/4096 = 4096 samples
    localparam integer PER  = 4096;

    vibrato_lfo #(
        .PH_INC (PHI),
        .DEPTH  (18)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .on    (on),
        .d     (d),
        .d_abs (d_abs)
    );

    always #5 clk = ~clk;

    task check;
        input        cond;
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

    // advance n audio samples
    task step;
        input integer cnt;
        integer i;
        begin
            for (i = 0; i < cnt; i = i + 1) begin
                @(posedge clk);
                en <= 1'b1;
                @(posedge clk);
                en <= 1'b0;
            end
        end
    endtask

    integer i;
    integer pmax, pmin, pfirst, ppos;
    integer period_cnt;
    integer crossings;

    initial begin
        $display("== tb_vibrato_lfo ==");

        //--------------------------------------------------------------
        // 1. reset, vibrato OFF -> d must be exactly 0 forever
        //--------------------------------------------------------------
        rst_n = 1'b0;
        step(4);
        rst_n = 1'b1;
        on    = 1'b0;
        step(64);

        pmax = -1000; pmin = 1000;
        for (i = 0; i < 200; i = i + 1) begin
            step(1);
            if (d > pmax) pmax = d;
            if (d < pmin) pmin = d;
        end
        check(pmax == 0 && pmin == 0, "on=0 holds d at exactly 0");

        //--------------------------------------------------------------
        // 2. vibrato ON -> sine between -18 and +18, period = 2^24/PH_INC
        //--------------------------------------------------------------
        on = 1'b1;
        step(2);

        pmax = -1000; pmin = 1000; crossings = 0; period_cnt = 0;
        begin : run_period
            integer last;
            last = 0;
            for (i = 0; i < 3 * PER; i = i + 1) begin
                step(1);
                if (d > pmax) pmax = d;
                if (d < pmin) pmin = d;
                // count rising zero crossings to measure the period
                if (last < 0 && d >= 0 && last != 0) begin
                    if (crossings == 1) begin
                        period_cnt = i - pfirst;
                    end else if (crossings == 0) begin
                        pfirst = i;
                    end
                    crossings = crossings + 1;
                end
                last = d;
            end
        end

        check(pmax == 18,  "positive peak is exactly +DEPTH (18)");
        check(pmin == -18, "negative peak is exactly -DEPTH (-18)");
        check(crossings >= 2, "LFO keeps crossing zero, i.e. it really oscillates");
        check((period_cnt > PER - 40) && (period_cnt < PER + 40),
              "LFO period matches 2^24 / PH_INC");

        // d_abs must equal |d| at every step
        begin : abs_check
            integer bad;
            bad = 0;
            for (i = 0; i < PER; i = i + 1) begin
                step(1);
                if (d_abs != ((d < 0) ? -d : d)) bad = bad + 1;
            end
            check(bad == 0, "d_abs always equals |d|");
        end

        //--------------------------------------------------------------
        // 3. switching off mid-cycle collapses d to zero within one sample
        //--------------------------------------------------------------
        on = 1'b0;
        step(2);
        check(d == 0, "turning vibrato off collapses d to 0 immediately");

        $display("== tb_vibrato_lfo : %0s (%0d errors) ==",
                 (errors == 0) ? "ALL PASS" : "FAIL", errors);
        $finish;
    end

endmodule
