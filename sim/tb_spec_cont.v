//  tb_spec_cont.v -- spectrum16 with a CONTINUOUS-PHASE tone.
//
//  tb_spectrum16 feeds a block-periodic tone, which is the easy case: every
//  block is exactly periodic so a rectangular window sees no discontinuity.
//  The real instrument is nothing like that -- a note free-runs across block
//  boundaries, so each 512-sample window starts and ends at an arbitrary
//  phase and the abrupt edges splatter energy over the whole band.  That is
//  the case this testbench reproduces: one sine at C4 (261.63 Hz, which is
//  2.78 bins -- deliberately off centre) whose phase never resets.
//
//  It prints the 16 bar levels so the shape of the display can be judged, and
//  asserts the two things that actually matter for the demo:
//    * the bars carrying the note are lit
//    * most of the band is dark, i.e. the display is not a solid block

`timescale 1ns / 1ps

module tb_spec_cont;

    localparam integer N     = 512;
    localparam integer NBINS = 16;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  signed [15:0] xin = 16'sd0;
    reg  en = 1'b0;
    wire [4*NBINS-1:0] lvl_flat;

    integer errors = 0;

    spectrum16 #(.NLOG(9), .NBINS(NBINS)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .xin(xin), .lvl_flat(lvl_flat)
    );

    always #5 clk = ~clk;

    //------------------------------------------------------------------
    // continuous-phase sine generator, advanced once per enable
    //------------------------------------------------------------------
    reg signed [15:0] tab [0:1023];
    initial $readmemh("rtl/audio/wav_bank_4096.mem", tab);   // first 1024 = sine

    reg [31:0] ph = 32'd0;
    // C4 at fs = 48.2142857 kHz -> inc = round(261.626*2^32/48214.2857)
    localparam [31:0] INC = 32'h01639E57;

    integer i, b, l, lit, maxl, maxb;

    task chk;
        input c;
        input [511:0] name;
        begin
            if (c) $display("PASS  %0s", name);
            else begin $display("FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // one analysis sample: hold en for one clock, then wait for the sweep
    task push_one;
        input integer v;
        begin
            @(negedge clk);
            xin = v[15:0];
            en  = 1'b1;
            @(negedge clk);
            en  = 1'b0;
            repeat (200) @(negedge clk);        // 32-clock publish + margin
        end
    endtask

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // two full blocks so the pipeline (and AGC) is settled
        for (i = 0; i < 2 * N; i = i + 1) begin
            ph = ph + INC;
            push_one((26000 * $signed(tab[ph[31:22]])) / 32768);
        end

        $display("");
        $display("      bar levels, C4 continuous phase (bin numbers 1..16):");
        lit = 0; maxl = 0; maxb = 0;
        for (b = 1; b <= NBINS; b = b + 1) begin
            l = lvl_flat[(b-1)*4 +: 4];
            $display("        bin %2d : %2d  %0s", b, l,
                     (l > 0) ? "####" : "");
            if (l > 0) lit = lit + 1;
            if (l > maxl) begin maxl = l; maxb = b; end
        end
        $display("      lit bins = %0d, loudest = bin %0d at level %0d",
                 lit, maxb, maxl);
        $display("");

        // C4 is 261.63 Hz / 94.174 Hz per bin = 2.78 bins -> bins 2..4
        chk((lvl_flat[1*4 +: 4] > 0) || (lvl_flat[2*4 +: 4] > 0),
            "the note lights its own bins (bin 2 or 3)");
        chk(lit <= 10, "the display is not a solid block of bars");
        chk(lit >= 1,  "at least one bar is lit");

        $display("");
        if (errors == 0) $display("== tb_spec_cont : ALL PASS ==");
        else             $display("== tb_spec_cont : %0d FAILURES ==", errors);
        $finish;
    end

    initial begin
        #20000000;
        $display("== tb_spec_cont : TIMEOUT ==");
        $finish;
    end

endmodule
