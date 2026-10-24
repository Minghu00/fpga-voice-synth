`timescale 1ns / 1ps

module tb_adsr;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg        en    = 1'b1;
    reg        gate  = 1'b0;
    wire [15:0] env;

    integer errors = 0;
    reg     saw_max = 1'b0;

    always #7.4 clk = ~clk;

    always @(posedge clk) begin
        if (env == 16'd65535)
            saw_max <= 1'b1;
    end

    adsr dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .gate  (gate),
        .env   (env)
    );

    task wait_clk;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    task check;
        input [255:0] name;
        input         cond;
        begin
            if (cond !== 1'b1) begin
                $display("FAIL: %0s (env=%0d @%0t)", name, env, $time);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s (env=%0d @%0t)", name, env, $time);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        wait_clk(10);
        rst_n = 1'b1;
        wait_clk(5);

        check("idle env=0", env == 16'd0);

        $display("-- gate on: attack --");
        saw_max = 1'b0;
        gate = 1'b1;
        wait_clk(250);
        check("attack reached max", saw_max == 1'b1);

        $display("-- decay --");
        wait_clk(100);
        check("decay decreasing", (env < 16'd65535) && (env > 16'd39321));

        $display("-- sustain --");
        wait_clk(6000);
        check("sustain level held", env == 16'd39321);

        $display("-- release --");
        gate = 1'b0;
        wait_clk(100);
        check("release decreasing", (env < 16'd39321) && (env > 16'd0));
        wait_clk(10000);
        check("release reached zero", env == 16'd0);

        $display("-- retrigger --");
        saw_max = 1'b0;
        gate = 1'b1;
        wait_clk(250);
        check("retrigger attack", saw_max == 1'b1);

        if (errors == 0)
            $display("==== ALL TESTS PASSED ====");
        else
            $display("==== %0d TEST(S) FAILED ====", errors);

        $stop;
    end

endmodule
