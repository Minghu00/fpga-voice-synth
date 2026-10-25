//  tb_vib_path.v -- does the vibrato term actually reach inc_org?
//
//  The Gowin optimiser reports NL0002 "vibrato_lfo instantiated to u_lfo is
//  swept" for the full instrument, which would mean the vibrato never reaches
//  the oscillators.  This test drives osc_bank directly and checks the two
//  things that would be true if the path were dead:
//
//    * with vib_d = 0 the base increment is exactly the LUT value
//    * with vib_d != 0 the base increment MOVES by roughly inc*d/1024
//
//  It also checks the sign: a positive vib_d must raise the increment.

`timescale 1ns / 1ps

module tb_vib_path;

    localparam integer VOICES = 8;
    localparam integer NCOMP  = 4;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  [11:0] fc = 12'd0;
    reg  [5*VOICES-1:0] note_flat = {5*VOICES{1'b0}};
    reg  [1:0] timbre = 2'd0;
    reg  [1:0] oct = 2'd0;
    reg  wave_mode = 1'b0;
    reg  glide_en = 1'b0;
    reg  signed [5:0] vib_d = 6'sd0;
    wire [16*VOICES-1:0] raw_flat;

    integer errors = 0;

    osc_bank #(.VOICES(VOICES), .NCOMP(NCOMP)) dut (
        .clk(clk), .rst_n(rst_n), .fc(fc), .note_flat(note_flat),
        .timbre(timbre), .oct(oct), .wave_mode(wave_mode),
        .glide_en(glide_en), .vib_d(vib_d), .raw_flat(raw_flat)
    );

    always #5 clk = ~clk;

    //  probe: sample the staged values whenever the base increment is written
    integer pn = 0;
    always @(posedge clk) begin
        if (rst_n && (pn < 8) && (fc == 12'd518) && (dut.fc[3:0] == 4'd6)) begin
            $display("      probe fc=%0d vib_d=%0d gl_q=%0d vp_q=%0d fin_q=%0d",
                     fc, vib_d, $signed(dut.gl_q), $signed(dut.vp_q), $signed(dut.fin_q));
            pn = pn + 1;
        end
    end

    task chk;
        input c;
        input [511:0] name;
        begin
            if (c) $display("PASS  %0s", name);
            else begin $display("FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // one whole frame: 2240 clocks, fc 0..2239
    task run_frame;
        integer i;
        begin
            for (i = 0; i < 2240; i = i + 1) begin
                @(negedge clk);
                fc = i[11:0];
            end
            @(negedge clk);
            fc = 12'd0;
        end
    endtask

    localparam [31:0] C4 = 32'h01639E57;      // inc_lut entry for note 0
    reg [31:0] base0, base1;

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        //---- vib_d = 0 : the base increment must be the plain LUT value ----
        vib_d = 6'sd0;
        run_frame;
        run_frame;
        base0 = dut.inc_org[0];
        $display("      vib_d = 0   -> inc_org[0] = %08x (lut %08x)", base0, C4);
        chk(base0 === C4, "vib_d = 0 gives exactly the table increment");

        //---- vib_d = +16 : inc must rise by about inc*16/1024 = inc/64 ----
        vib_d = 6'sd16;   // +32 does not fit a 6-bit signed port (it wraps to -32)
        run_frame;
        run_frame;
        base1 = dut.inc_org[0];
        $display("      vib_d = +16 -> inc_org[0] = %08x  (expected ~%08x)",
                 base1, C4 + (C4 >> 6));
        chk(base1 > C4, "a positive vib_d raises the base increment");
        chk(base1 != base0, "the vibrato term actually reaches inc_org");

        //  16/1024 = 1/64, allow a few counts of rounding through the
        //  33-bit >>10 truncation
        chk((base1 - C4) > ((C4 >> 7)) && (base1 - C4) < ((C4 >> 5)),
            "the detune size matches inc * d / 1024");

        //---- negative vib_d must lower it ----
        vib_d = -6'sd16;
        run_frame;
        run_frame;
        base1 = dut.inc_org[0];
        $display("      vib_d = -16 -> inc_org[0] = %08x", base1);
        chk(base1 < C4, "a negative vib_d lowers the base increment");

        //---- back to 0 : must return exactly, i.e. no residue ----
        vib_d = 6'sd0;
        run_frame;
        run_frame;
        chk(dut.inc_org[0] === C4, "vib_d = 0 again restores the exact value");

        $display("");
        if (errors == 0) $display("== tb_vib_path : ALL PASS ==");
        else             $display("== tb_vib_path : %0d FAILURES ==", errors);
        $finish;
    end

endmodule
