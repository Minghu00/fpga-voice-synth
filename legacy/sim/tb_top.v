`timescale 1ns / 1ps

module tb_top;

    reg        clk27 = 1'b0;
    reg        rst_n = 1'b0;
    reg  [3:0] key_n = 4'b1111;
    wire       i2s_bclk;
    wire       i2s_lrclk;
    wire       i2s_din;

    integer errors   = 0;
    integer din_poses = 0;
    integer din_snap  = 0;
    time    t_press;
    time    t_trig;
    time    t_audio;
    time    latency;

    always #18.5185 clk27 = ~clk27;

    top #(
        .DEBOUNCE_MS (1)
    ) dut (
        .clk27     (clk27),
        .rst_n     (rst_n),
        .key_n     (key_n),
        .i2s_bclk  (i2s_bclk),
        .i2s_lrclk (i2s_lrclk),
        .i2s_din   (i2s_din)
    );

    always @(posedge i2s_din) din_poses = din_poses + 1;

    task check;
        input [255:0] name;
        input         cond;
        begin
            if (cond !== 1'b1) begin
                $display("FAIL: %0s @%0t", name, $time);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s @%0t", name, $time);
            end
        end
    endtask

    task press_release;
        input [1:0] idx;
        begin
            key_n[idx] = 1'b0;
            #2000000;
            key_n[idx] = 1'b1;
            #2000000;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #1000;
        rst_n = 1'b1;
        #2000;

        check("trig all off after reset", dut.trig == 4'b0000);

        $display("-- key0: debounce + latch + sound --");
        fork
            begin
                @(posedge dut.trig[0]);
                t_trig = $time;
                wait (dut.v0 !== 16'sd0);
                t_audio = $time;
            end
        join_none

        t_press   = $time;
        key_n[0]  = 1'b0;
        wait (dut.trig[0] === 1'b1);
        key_n[0]  = 1'b1;
        #2000000;

        check("key0 latched on", dut.trig[0] === 1'b1);
        latency = t_audio - t_trig;
        $display("info: trig->audio latency = %0t", latency);
        check("trig->audio latency < 100us", latency < 100000);

        din_snap = din_poses;
        #5000000;
        check("I2S data active on key0", din_poses > din_snap + 100);

        $display("-- keys 1..3: four-voice polyphony --");
        press_release(2'd1);
        check("key1 latched on", dut.trig[1] === 1'b1);
        press_release(2'd2);
        check("key2 latched on", dut.trig[2] === 1'b1);
        press_release(2'd3);
        check("key3 latched on", dut.trig[3] === 1'b1);
        #5000000;
        check("all four voices latched", dut.trig == 4'b1111);

        din_snap = din_poses;
        #5000000;
        check("I2S data active with four voices", din_poses > din_snap + 100);

        $display("-- key0 toggle off --");
        press_release(2'd0);
        check("key0 latched off", dut.trig[0] === 1'b0);
        check("others still on", dut.trig[3:1] === 3'b111);

        if (errors == 0)
            $display("==== ALL TESTS PASSED ====");
        else
            $display("==== %0d TEST(S) FAILED ====", errors);

        $stop;
    end

endmodule
