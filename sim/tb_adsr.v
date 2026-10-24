//=============================================================================
// tb_adsr.v  --  self-checking testbench for adsr
//
//  Uses short steps so the whole envelope fits in a few hundred samples.
//      ATT_STEP 1000  (66 samples to full)
//      DEC_STEP  500  (71 samples to sustain)
//      REL_STEP 2000  (15 samples from sustain to silence)
//      SUSTAIN 30000
//=============================================================================
`timescale 1ns / 1ps

module tb_adsr;

    localparam [15:0] ATT = 16'd1000;
    localparam [15:0] DEC = 16'd500;
    localparam [15:0] REL = 16'd2000;
    localparam [15:0] SUS = 16'd30000;

    localparam [2:0] S_IDLE = 3'd0, S_ATT = 3'd1, S_DEC = 3'd2,
                     S_SUS  = 3'd3, S_REL = 3'd4;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg         en    = 1'b0;
    reg         gate  = 1'b0;
    wire [15:0] env;
    wire        active;

    integer errors = 0;
    integer n;

    always #4.6296 clk = ~clk;

    adsr #(
        .ATT_STEP (ATT),
        .DEC_STEP (DEC),
        .REL_STEP (REL),
        .SUSTAIN  (SUS)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .gate  (gate),
        .env   (env),
        .active(active)
    );

    task tick;
        begin
            @(posedge clk);
            en <= 1'b1;
            @(posedge clk);
            en <= 1'b0;
            @(posedge clk);
        end
    endtask

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

    initial begin
        $dumpfile("sim/tb_adsr.vcd");
        $dumpvars(0, tb_adsr);

        #200 rst_n = 1'b1;

        //------------------------------------------------------------------
        // 1. silent while gate is low
        //------------------------------------------------------------------
        tick; tick; tick;
        check("idle: env == 0", env == 16'd0);
        check("idle: active == 0", active == 1'b0);

        //------------------------------------------------------------------
        // 2. attack starts, rises by ATT_STEP per sample
        //------------------------------------------------------------------
        gate = 1'b1;
        tick;                                  // IDLE -> ATT, env still 0
        check("attack: first sample env == 0", env == 16'd0);
        tick;
        check("attack: env ramps by ATT_STEP", env == ATT);
        check("attack: active == 1", active == 1'b1);

        //------------------------------------------------------------------
        // 3. attack saturates, then decays to sustain and holds
        //------------------------------------------------------------------
        n = 0;
        while ((dut.state != S_SUS) && (n < 400)) begin
            tick;
            n = n + 1;
        end
        check("decay reached sustain state", dut.state == S_SUS);
        check("sustain level correct", env == SUS);

        tick; tick; tick;
        check("sustain holds level", env == SUS);

        //------------------------------------------------------------------
        // 4. release to silence
        //------------------------------------------------------------------
        gate = 1'b0;
        tick;
        check("release entered", dut.state == S_REL);
        // entering release does not change the level on that same sample
        check("release holds level on entry", env == SUS);
        tick;
        check("release decrements", env == SUS - REL);

        n = 0;
        while ((dut.state != S_IDLE) && (n < 200)) begin
            tick;
            n = n + 1;
        end
        check("release reached idle", dut.state == S_IDLE);
        check("release env == 0", env == 16'd0);
        check("release active == 0", active == 1'b0);

        //------------------------------------------------------------------
        // 5. re-strike while releasing -> attack again
        //------------------------------------------------------------------
        gate = 1'b1;
        n = 0;
        while ((dut.state != S_SUS) && (n < 400)) begin
            tick;
            n = n + 1;
        end
        gate = 1'b0;
        tick; tick;
        check("release from sustain", dut.state == S_REL);
        gate = 1'b1;
        tick;
        check("re-strike goes back to attack", dut.state == S_ATT);

        //------------------------------------------------------------------
        // 6. frozen when en is low
        //------------------------------------------------------------------
        gate = 1'b1;
        tick;
        n = env;
        @(posedge clk); @(posedge clk); @(posedge clk);
        check("env frozen while en == 0", env == n);

        if (errors == 0)
            $display("== tb_adsr : ALL PASS ==");
        else
            $display("== tb_adsr : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
