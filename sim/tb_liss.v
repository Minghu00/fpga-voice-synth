//============================================================================
//  tb_liss.v -- self-checking testbench for liss_render
//
//  Checks the three things that can silently break the Lissajous page:
//     1. the clear pass really marks every column empty ({ymax,ymin}={0,255})
//     2. a DC input lands on exactly one column at exactly the mapped row
//     3. a bipolar input produces the right ymin/ymax span, i.e. the figure is
//        a filled band rather than a single row
//  plus the arithmetic of the >>> 6 mapping and the clamps at both edges.
//============================================================================
`timescale 1ns / 1ps

module tb_liss;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         vblank = 1'b0;
    wire [8:0]  hist_addr;
    wire [15:0] hist_l, hist_r;
    reg  [8:0]  disp_addr = 9'd0;
    wire [15:0] disp_span;

    always #5 clk = ~clk;

    // history contents: set by the test, shared by both channels' readers
    reg [15:0] mem_l [0:511];
    reg [15:0] mem_r [0:511];

    assign hist_l = mem_l[hist_addr];
    assign hist_r = mem_r[hist_addr];

    liss_render dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .vblank   (vblank),
        .hist_addr(hist_addr),
        .hist_l   (hist_l),
        .hist_r   (hist_r),
        .disp_addr(disp_addr),
        .disp_span(disp_span)
    );

    integer errors = 0;
    integer i;

    task chk;
        input [511:0] name;
        input         ok;
        begin
            if (ok) $display("PASS  %0s", name);
            else begin
                $display("FAIL  %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_num;
        input [511:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp) $display("PASS  %0s : %0d", name, got);
            else begin
                $display("FAIL  %0s : got %0d want %0d", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // read one span back through the display port
    reg [15:0] rd;
    task rd_col;
        input [8:0] col;
        begin
            @(posedge clk); #1;
            disp_addr = col;
            repeat (3) @(posedge clk);   // 1 addr + 1 RAM latency + 1 margin
            #1 rd = disp_span;
        end
    endtask

    // fill both channels with a constant pair, then run one blanking pass
    task fill_const;
        input signed [15:0] l;
        input signed [15:0] r;
        begin
            @(posedge clk); #1;
            for (i = 0; i < 512; i = i + 1) begin
                mem_l[i] = l;
                mem_r[i] = r;
            end
        end
    endtask

    task run_blank;
        begin
            @(posedge clk); #1;
            vblank = 1'b1;
            repeat (6000) @(posedge clk);   // 512 clear + 512*6 accumulate, with margin
            @(posedge clk); #1;
            vblank = 1'b0;
            repeat (10) @(posedge clk);
        end
    endtask

    reg signed [15:0] lv, rv;

    initial begin
        $dumpfile("sim/tb_liss.vcd");
        $dumpvars(0, tb_liss);

        for (i = 0; i < 512; i = i + 1) begin
            mem_l[i] = 16'sd0;
            mem_r[i] = 16'sd0;
        end

        repeat (5) @(posedge clk);
        @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        //------------------------------------------------------------------
        // 1. clear pass
        //------------------------------------------------------------------
        fill_const(16'sd0, 16'sd0);
        run_blank;
        // constant 0 -> column 240, row 68
        rd_col(9'd240);
        chk_num("DC 0/0 lands on column 240 at row 68", rd, {8'd68, 8'd68});

        //------------------------------------------------------------------
        // 2. every other column is empty
        //------------------------------------------------------------------
        rd_col(9'd0);
        chk_num("column 0 is marked empty", rd, 16'h00FF);
        rd_col(9'd479);
        chk_num("column 479 is marked empty", rd, 16'h00FF);

        //------------------------------------------------------------------
        // 3. mapping: L -> column, R -> row.  1 count = 1/64 pixel.
        //    L = +6400 -> 240 + 100 = 340 ; R = -3200 -> 68 - 50 = 18
        //------------------------------------------------------------------
        fill_const(16'sd6400, -16'sd3200);
        run_blank;
        rd_col(9'd340);
        chk_num("L=+6400 maps to column 340, R=-3200 to row 18", rd, {8'd18, 8'd18});

        //------------------------------------------------------------------
        // 4. bipolar input -> a filled band, not one row
        //    alternate R between +3200 and -3200 on the same column
        //------------------------------------------------------------------
        @(posedge clk); #1;
        for (i = 0; i < 512; i = i + 1) begin
            mem_l[i] = 16'sd0;
            mem_r[i] = (i[0]) ? -16'sd3200 : 16'sd3200;
        end
        run_blank;
        rd_col(9'd240);
        chk_num("bipolar R fills rows 18..118 in column 240", rd, {8'd118, 8'd18});

        //------------------------------------------------------------------
        // 5. clamps: a full-scale negative L must not wrap below column 0
        //------------------------------------------------------------------
        fill_const(-16'sd32768, 16'sd0);
        run_blank;
        rd_col(9'd0);
        chk("full-scale negative L clamps to column 0", rd != 16'h00FF);
        rd_col(9'd479);
        chk_num("no wrap-around onto the far right column", rd, 16'h00FF);

        //------------------------------------------------------------------
        // 6. clamps: a full-scale positive R must not wrap below row 135
        //------------------------------------------------------------------
        fill_const(16'sd0, 16'sd32767);
        run_blank;
        rd_col(9'd240);
        chk_num("full-scale positive R clamps to row 135", rd, {8'd135, 8'd135});

        //------------------------------------------------------------------
        // 7. a horizontal sweep spreads the figure across columns
        //------------------------------------------------------------------
        @(posedge clk); #1;
        for (i = 0; i < 512; i = i + 1) begin
            mem_l[i] = i * 32;              // 0..16352 -> columns 240..495 (clamped)
            mem_r[i] = 16'sd0;
        end
        run_blank;
        begin : spread
            integer nonempty;
            nonempty = 0;
            for (i = 0; i < 512; i = i + 1) begin
                rd_col(i[8:0]);
                if (rd != 16'h00FF) nonempty = nonempty + 1;
            end
            chk("a horizontal sweep lights many columns",
                nonempty > 200);
        end

        //------------------------------------------------------------------
        // 8. an empty input must leave the whole table empty again
        //------------------------------------------------------------------
        fill_const(16'sd0, 16'sd0);
        run_blank;
        begin : cleared
            integer nonempty;
            nonempty = 0;
            for (i = 0; i < 512; i = i + 1) begin
                rd_col(i[8:0]);
                if (rd != 16'h00FF) nonempty = nonempty + 1;
            end
            chk_num("only the single 0/0 column survives", nonempty, 1);
        end

        if (errors == 0) $display("\n== tb_liss : ALL PASS ==");
        else             $display("\n== tb_liss : %0d FAILURES ==", errors);

        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
