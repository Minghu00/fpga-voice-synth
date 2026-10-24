`timescale 1ns / 1ps

module tb_key_ctrl;

    localparam CLK_FREQ    = 100_000;
    localparam DEBOUNCE_MS = 1;
    localparam T           = 1_000_000_000 / CLK_FREQ;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg  [3:0] key_n = 4'b1111;
    wire [3:0] trig;
    integer    errors = 0;

    always #(T/2) clk = ~clk;

    key_ctrl #(
        .KEY_NUM     (4),
        .CLK_FREQ    (CLK_FREQ),
        .DEBOUNCE_MS (DEBOUNCE_MS)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .key_n (key_n),
        .trig  (trig)
    );

    task press;
        input [1:0] idx;
        begin
            key_n[idx] = 1'b0;
            #(3_000_000);
        end
    endtask

    task rel;
        input [1:0] idx;
        begin
            key_n[idx] = 1'b1;
            #(3_000_000);
        end
    endtask

    task check;
        input [1:0] idx;
        input       exp;
        begin
            if (trig[idx] !== exp) begin
                $display("FAIL: trig[%0d]=%b expected %b @%0t", idx, trig[idx], exp, $time);
                errors = errors + 1;
            end else begin
                $display("PASS: trig[%0d]=%b @%0t", idx, trig[idx], $time);
            end
        end
    endtask

    integer i;

    initial begin
        rst_n = 1'b0;
        #1000;
        rst_n = 1'b1;
        #1000;

        check(0, 1'b0);
        check(1, 1'b0);
        check(2, 1'b0);
        check(3, 1'b0);

        $display("-- key0 press+release -> latch on --");
        press(0);
        rel(0);
        check(0, 1'b1);

        $display("-- key0 press+release again -> latch off --");
        press(0);
        rel(0);
        check(0, 1'b0);

        $display("-- key1 press+release, key0 unaffected --");
        press(1);
        rel(1);
        check(1, 1'b1);
        check(0, 1'b0);

        $display("-- key2 with contact bounce --");
        for (i = 0; i < 20; i = i + 1) begin
            key_n[2] = ~key_n[2];
            #(20_000);
        end
        key_n[2] = 1'b0;
        #(3_000_000);
        for (i = 0; i < 20; i = i + 1) begin
            key_n[2] = ~key_n[2];
            #(20_000);
        end
        key_n[2] = 1'b1;
        #(3_000_000);
        check(2, 1'b1);

        $display("-- key3 while key2 held --");
        press(3);
        rel(3);
        check(3, 1'b1);
        check(2, 1'b1);

        if (errors == 0)
            $display("==== ALL TESTS PASSED ====");
        else
            $display("==== %0d TEST(S) FAILED ====", errors);

        $stop;
    end

endmodule
