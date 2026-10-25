//============================================================================
//  tb_spectrum16.v -- self-checking testbench for spectrum16
//
//  The block only needs `en` to arrive at least 64 clocks apart (one full bin
//  sweep); production gives it 2240.  The bench therefore pulses en every
//  128 clocks and feeds an exact-integer sine that sits ON a bin centre, so
//  the expected accumulator values can be computed in closed form:
//
//      bin k, amplitude A  ->  |Re|+|Im| = A * N/2 = A * 256
//
//  and the published level is (msb(|Re|+|Im|) - 8), clamped to 0..15.
//
//  STIMULUS DISCIPLINE: `en` is driven on the FALLING edge.  Driving it with
//  a blocking assignment right after "@(posedge clk)" races the DUT's own
//  posedge block in the same time step -- the bench wins the race, `en` is
//  already back to 0 when the DUT samples it, and every accumulator stays at
//  zero.  That exact race cost a debugging round.
//============================================================================
`timescale 1ns / 1ps

module tb_spectrum16;
    localparam integer N     = 512;
    localparam integer NHALF = 256;
    localparam integer ENP   = 128;         // clocks between enables

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg en = 1'b0;
    reg signed [15:0] xin = 16'sd0;
    wire [63:0] lvl_flat;

    always #5 clk = ~clk;

    spectrum16 dut (
        .clk(clk), .rst_n(rst_n), .en(en), .xin(xin), .lvl_flat(lvl_flat)
    );

    //  local reference table, identical to rtl/display/spectrum_sin.mem
    reg [15:0] ref_tab [0:N-1];
    initial $readmemh("rtl/display/spectrum_sin.mem", ref_tab);

    integer errors = 0;
    task chk;
        input        cond;
        input [511:0] name;
        begin
            if (cond) $display("PASS  %0s", name);
            else begin $display("FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    task chk_num;
        input [511:0] name;
        input integer got, want;
        begin
            if (got === want) $display("PASS  %0s : %0d", name, got);
            else begin
                $display("FAIL  %0s : got %0d want %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    //------------------------------------------------------------------
    // expected level for a pure tone of amplitude a on a bin centre
    //
    // The DUT scales each product by 2^-10 (see spectrum16.v: un-scaled the
    // accumulate overflows 32 bits).  A matched bin therefore sums to
    //     a^2 * N/2 / 1024 = a^2 * 256 / 1024 = a^2 / 4
    // and the level is msb(that) - 12, clamped to 0..15.  Full scale lands on
    // msb 27 -> 15, and each halving of amplitude is exactly one level.
    //------------------------------------------------------------------
    function integer exp_lvl;
        input integer a;
        integer mag, msb, i;
        begin
            mag = (a * a) / 16;             // a^2/16, kept inside 32 bit
            msb = 0;
            for (i = 0; i < 32; i = i + 1) if (mag[i]) msb = i;
            if (msb <= 10) exp_lvl = 0;
            else if (msb >= 25) exp_lvl = 15;
            else exp_lvl = msb - 10;
        end
    endfunction

    //------------------------------------------------------------------
    // push one whole analysis block: N samples, one every ENP clocks.
    // bin = 0 means silence.  Positive/negative handled by $signed().
    //------------------------------------------------------------------
    integer idx, vv;
    task push_one;
        input integer value;
        begin
            @(negedge clk);
            xin = value[15:0];
            en  = 1'b1;
            @(negedge clk);                 // one posedge samples en = 1
            en  = 1'b0;
            repeat (ENP - 2) @(negedge clk);
        end
    endtask

    task push_block;
        input integer bin;
        input integer a;
        integer i;
        begin
            for (i = 0; i < N; i = i + 1) begin
                if (bin == 0) push_one(0);
                else          push_one((a * $signed(ref_tab[(bin * i) % N])) / 32768);
            end
            repeat (40) @(negedge clk);     // let the publish pass finish
        end
    endtask

    //  lvl_flat is indexed by the STORAGE slot b = k-1, because bin number
    //  k runs 1..16 (k = 0 would be DC).  This helper takes the bin NUMBER.
    task lvl_of;
        input  integer k;
        output integer l;
        begin
            l = lvl_flat[(k-1)*4 +: 4];
        end
    endtask

    integer l, b, maxl, maxb, others, far;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_spectrum16.vcd");
            $dumpvars(0, tb_spectrum16);
        end

        //--------------------------------------------------------------
        // 1. reset state
        //--------------------------------------------------------------
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        chk(lvl_flat === 64'd0, "all levels are zero after reset");

        //--------------------------------------------------------------
        // 2. bin 3 at full scale
        //--------------------------------------------------------------
        push_block(3, 32767);
        lvl_of(3, l);
        $display("      bin3 level = %0d", l);
        chk_num("full-scale tone on bin 3 gives its expected level", l, exp_lvl(32767));
        maxl = 0; maxb = 0; others = 0; far = 0;
        for (b = 1; b <= 16; b = b + 1) begin
            lvl_of(b, l);
            if (b != 3) begin
                if (l > maxl) begin maxl = l; maxb = b; end
                others = others + l;
                if ((b < 2) || (b > 4)) if (l > far) far = l;
            end
        end
        $display("      strongest other bin = %0d (bin %0d), sum of others = %0d",
                 maxl, maxb, others);
        //  With the triangular window a bin-centred tone has a 4-bin-wide main
        //  lobe, so bin 2 and bin 4 legitimately light up (about -6 dB, i.e.
        //  level 13).  What must NOT happen is energy leaking far away: bins
        //  three or more away from the tone must stay dark.
        $display("      farthest lit bin 3+ away = %0d", far);
        chk(far <= 8, "bins 3 or more away from the tone are at least 30 dB down");
        lvl_of(2, l); chk(l >= 10, "the +-1 bin neighbour is in the main lobe (bin 2)");
        lvl_of(4, l); chk(l >= 10, "the +-1 bin neighbour is in the main lobe (bin 4)");

        //--------------------------------------------------------------
        // 3. bin 10 at half scale.  The level scale is relative to the block
        //    peak, so a half-amplitude tone still reads full scale -- that is
        //    the point of the AGC (the display must not dim when the volume
        //    is turned down).  What must hold is that the old bin is dark.
        //--------------------------------------------------------------
        push_block(10, 16384);
        lvl_of(10, l);
        $display("      bin10 level = %0d (AGC: still full scale)", l);
        chk(l >= 14, "half-scale tone still reads near full scale (AGC)");
        lvl_of(3, l);
        chk(l <= 3, "bin 3 has gone quiet after the tone moved");

        //--------------------------------------------------------------
        // 4. silence clears the display
        //--------------------------------------------------------------
        push_block(0, 0);
        others = 0;
        for (b = 1; b <= 16; b = b + 1) begin
            lvl_of(b, l);
            others = others + l;
        end
        chk_num("silence clears every bin", others, 0);

        //--------------------------------------------------------------
        // 5. two tones at once -- both bins light up, the gap stays dark
        //--------------------------------------------------------------
        for (idx = 0; idx < N; idx = idx + 1) begin
            vv = (16384 * $signed(ref_tab[(2 * idx) % N])) / 32768
               + (16384 * $signed(ref_tab[(11 * idx) % N])) / 32768;
            push_one(vv);
        end
        repeat (40) @(negedge clk);
        lvl_of(2, l);
        $display("      two-tone: bin2 = %0d", l);
        chk(l >= 12, "two-tone: bin 2 is present");
        lvl_of(11, l);
        $display("      two-tone: bin11 = %0d", l);
        chk(l >= 12, "two-tone: bin 11 is present");
        lvl_of(6, l);
        $display("      two-tone: bin6 = %0d", l);
        chk(l <= 3, "two-tone: the empty bin between them stays dark");

        //--------------------------------------------------------------
        // 6. levels must be stable for a whole block (they are registered
        //    once per 512 samples, not per pixel)
        //--------------------------------------------------------------
        lvl_of(2, l);
        repeat (100) @(negedge clk);
        lvl_of(2, b);
        chk_num("levels do not change between blocks", b, l);

        $display("");
        if (errors == 0) $display("== tb_spectrum16 : ALL PASS ==");
        else             $display("== tb_spectrum16 : %0d FAILURES ==", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("== tb_spectrum16 : TIMEOUT ==");
        $finish;
    end

endmodule
