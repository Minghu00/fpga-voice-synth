`timescale 1ns / 1ps

module tb_synth_voice;

    localparam [31:0] TW0 = 32'h0165A690;
    localparam [31:0] TW1 = 32'h01C29C8F;
    localparam [31:0] TW2 = 32'h0217DED7;
    localparam [31:0] TW3 = 32'h02CB4D1F;

    reg               clk   = 1'b0;
    reg               rst_n = 1'b0;
    reg               en    = 1'b1;
    reg  [1:0]        note  = 2'd0;
    reg               gate  = 1'b1;
    reg  [15:0]       vel   = 16'hFFFF;
    wire signed [15:0] audio;

    integer errors = 0;

    always #7.4 clk = ~clk;

    synth_voice dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (en),
        .note_idx (note),
        .gate     (gate),
        .vel      (vel),
        .audio    (audio)
    );

    reg [31:0] p0;
    reg [31:0] p1;

    task check;
        input [255:0] name;
        input         cond;
        begin
            if (cond !== 1'b1) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s", name);
            end
        end
    endtask

    task test_note;
        input [1:0]  idx;
        input [31:0] tw;
        begin
            note = idx;
            rst_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);

            @(negedge clk);
            p0 = dut.phase;

            repeat (100) @(posedge clk);
            @(negedge clk);
            p1 = dut.phase;

            if ((p1 - p0) === (32'd100 * tw))
                $display("PASS: note_idx=%0d phase step correct (tw=%08X)", idx, tw);
            else begin
                $display("FAIL: note_idx=%0d phase delta=%08X expected=%08X", idx, p1 - p0, 32'd100 * tw);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;

        test_note(2'd0, TW0);
        test_note(2'd1, TW1);
        test_note(2'd2, TW2);
        test_note(2'd3, TW3);

        $display("-- audio activity --");
        note = 2'd0;
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;
        gate = 1'b1;
        #1000000;
        check("audio non-zero after gate", audio !== 16'sd0);

        if (errors == 0)
            $display("==== ALL TESTS PASSED ====");
        else
            $display("==== %0d TEST(S) FAILED ====", errors);

        $stop;
    end

endmodule
