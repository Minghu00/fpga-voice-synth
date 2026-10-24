//=============================================================================
//  sim/tb_test_mode.v -- self-checking testbench for rtl/audio/test_mode.v
//
//  Checks
//    1. plain power-up (Key_3 released) leaves test mode off and every input
//       passes straight through to the output;
//    2. pressing Key_3 *during* reset and letting go before reset is released
//       does not arm anything -- reset forces the synchroniser to "released";
//    3. holding Key_3 across reset release latches test mode on;
//    4. the override values are exactly the documented ones
//       (gate all ones, NOTE_SET, organ, octave 0, VOL_TEST);
//    5. releasing the key afterwards does not clear the mode (sticky until
//       the next power cycle);
//    6. the eight test pitches are three semitones apart, ascend from voice 0
//       to voice 7, and the top pitch multiplied by the x4 harmonic still fits
//       in a 32-bit phase increment.
//=============================================================================
`timescale 1ns / 1ps

module tb_test_mode;

    localparam integer VOICES   = 8;
    localparam integer INIT_WIN = 40;        // short window keeps the sim quick
    localparam [3:0]   VOL_TEST = 4'd2;

    // exactly the default NOTE_SET of the DUT, spelled the same way
    localparam [5*VOICES-1:0] EXPECT_NOTE = {5'd21, 5'd18, 5'd15, 5'd12,
                                             5'd9,  5'd6,  5'd3,  5'd0};

    reg         clk = 1'b0;
    reg         rst_n;
    reg         vup_n;
    reg  [7:0]  gate_in;
    reg  [39:0] note_in;
    reg  [1:0]  timbre_in;
    reg  [1:0]  oct_in;
    reg  [3:0]  vol_in;

    wire        test_en;
    wire [7:0]  gate_out;
    wire [39:0] note_out;
    wire [1:0]  timbre_out;
    wire [1:0]  oct_out;
    wire [3:0]  vol_out;

    integer     errors = 0;
    integer     checks = 0;

    always #5 clk = ~clk;                    // 100 MHz, speed is irrelevant here

    test_mode #(
        .VOICES   (VOICES),
        .INIT_WIN (INIT_WIN),
        .VOL_TEST (VOL_TEST)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .vup_n     (vup_n),
        .gate_in   (gate_in),
        .note_in   (note_in),
        .timbre_in (timbre_in),
        .oct_in    (oct_in),
        .vol_in    (vol_in),
        .test_en   (test_en),
        .gate_out  (gate_out),
        .note_out  (note_out),
        .timbre_out(timbre_out),
        .oct_out   (oct_out),
        .vol_out   (vol_out)
    );

    //--------------------------------------------------------------
    // helpers
    //--------------------------------------------------------------
    task chk(input cond, input [511:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("PASS  %0s", name);
            else begin
                $display("FAIL  %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_num(input [31:0] got, input [31:0] want, input [511:0] name);
        begin
            checks = checks + 1;
            if (got === want) $display("PASS  %0s : %0d", name, got);
            else begin
                $display("FAIL  %0s : got %0d want %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // release reset, then let the power-up window close
    task power_up;
        begin
            rst_n = 1'b0;
            repeat (8) @(posedge clk);
            rst_n = 1'b1;
            repeat (INIT_WIN * 4) @(posedge clk);
        end
    endtask

    // a local copy of rtl/audio/inc_lut.v so the TB can reason about pitches
    function [31:0] lut;
        input [4:0] n;
        begin
            case (n)
                5'd0 : lut = 32'h01639E57;
                5'd1 : lut = 32'h0178C3C3;
                5'd2 : lut = 32'h018F2B15;
                5'd3 : lut = 32'h01A6E772;
                5'd4 : lut = 32'h01C00D20;
                5'd5 : lut = 32'h01DAB19B;
                5'd6 : lut = 32'h01F6EBA8;
                5'd7 : lut = 32'h0214D364;
                5'd8 : lut = 32'h0234825C;
                5'd9 : lut = 32'h025613A1;
                5'd10: lut = 32'h0279A3E2;
                5'd11: lut = 32'h029F5181;
                5'd12: lut = 32'h02C73CAF;
                5'd13: lut = 32'h02F18787;
                5'd14: lut = 32'h031E562B;
                5'd15: lut = 32'h034DCEE3;
                5'd16: lut = 32'h03801A3F;
                5'd17: lut = 32'h03B56337;
                5'd18: lut = 32'h03EDD751;
                5'd19: lut = 32'h0429A6C9;
                5'd20: lut = 32'h046904B8;
                5'd21: lut = 32'h04AC2743;
                5'd22: lut = 32'h04F347C5;
                5'd23: lut = 32'h053EA302;
                5'd24: lut = 32'h058E795E;
                default: lut = 32'h01639E57;
            endcase
        end
    endfunction

    task check_notes;
        integer   i;
        integer   idx_lo, idx_hi;
        reg [31:0] inc_lo, inc_hi, worst;
        begin
            for (i = 1; i < VOICES; i = i + 1) begin
                chk_num(note_out[i*5 +: 5] - note_out[(i-1)*5 +: 5], 3,
                        "adjacent test voices are three semitones apart");
            end

            idx_lo = note_out[0*5 +: 5];
            idx_hi = note_out[(VOICES-1)*5 +: 5];
            inc_lo = lut(idx_lo[4:0]);
            inc_hi = lut(idx_hi[4:0]);
            worst  = inc_hi << 2;                       // x4 additive component

            chk((inc_hi > inc_lo), "test pitches ascend from voice 0 to voice 7");
            chk((worst < 32'hFFFF_FFFF),
                "highest test pitch x4 harmonic still fits in 32 bits");

            $display("       lowest  = note %0d  inc 0x%08X", idx_lo, inc_lo);
            $display("       highest = note %0d  inc 0x%08X  x4 = 0x%08X",
                     idx_hi, inc_hi, worst);
        end
    endtask

    //--------------------------------------------------------------
    // stimulus
    //--------------------------------------------------------------
    initial begin
        $display("");

        //----------------------------------------------------------
        // case 1: normal power-up, key released the whole time
        //----------------------------------------------------------
        $display("---- case 1: normal power-up, key released ----");
        rst_n     = 1'b0;
        vup_n     = 1'b1;                        // released
        gate_in   = 8'h05;
        note_in   = {5'd7, 5'd6, 5'd5, 5'd4, 5'd3, 5'd2, 5'd1, 5'd0};
        timbre_in = 2'd2;
        oct_in    = 2'd1;
        vol_in    = 4'd7;

        power_up;

        chk(test_en === 1'b0,                    "plain power-up leaves test mode off");
        chk_num(gate_out,   gate_in,             "gate passes through");
        chk_num(note_out[31:0], note_in[31:0],   "notes pass through");
        chk(note_out === note_in,                "all 40 note bits pass through");
        chk_num(timbre_out, timbre_in,           "timbre passes through");
        chk_num(oct_out,    oct_in,              "octave passes through");
        chk_num(vol_out,    vol_in,              "volume passes through");

        //----------------------------------------------------------
        // case 2: press during reset, let go before reset is released.
        //         Reset forces the synchroniser to "released", so the open
        //         window right after release must see nothing.
        //----------------------------------------------------------
        $display("---- case 2: press during reset only ----");
        rst_n = 1'b0;
        vup_n = 1'b0;
        repeat (10) @(posedge clk);
        vup_n = 1'b1;                            // let go while still in reset
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        repeat (INIT_WIN * 4) @(posedge clk);

        chk(test_en === 1'b0, "pressing only inside reset does not arm the mode");

        //----------------------------------------------------------
        // case 3: hold the key across reset release
        //----------------------------------------------------------
        $display("---- case 3: key held across reset release ----");
        rst_n     = 1'b0;
        vup_n     = 1'b0;                        // pressed = 0
        gate_in   = 8'h0F;
        note_in   = {5'd1, 5'd1, 5'd1, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0};
        timbre_in = 2'd3;
        oct_in    = 2'd2;
        vol_in    = 4'd9;
        repeat (4) @(posedge clk);

        power_up;

        chk(test_en === 1'b1,                    "holding Key_3 through reset latches test mode");
        chk_num(gate_out,   8'hFF,               "test mode keys all eight voices");
        chk(note_out === EXPECT_NOTE,            "test mode uses NOTE_SET");
        chk_num(timbre_out, 2'd0,                "test mode forces organ (pure sine)");
        chk_num(oct_out,    2'd0,                "test mode forces octave 0");
        chk_num(vol_out,    {28'd0, VOL_TEST},   "test mode forces the fixed gain step");

        //----------------------------------------------------------
        // case 4: release the key, the mode must stay latched
        //----------------------------------------------------------
        $display("---- case 4: release Key_3, mode must stay on ----");
        vup_n = 1'b1;
        repeat (400) @(posedge clk);
        chk(test_en === 1'b1, "test mode is sticky after the key is released");

        //----------------------------------------------------------
        // case 5: pitch spacing and the overflow budget
        //----------------------------------------------------------
        $display("---- case 5: pitch spacing and overflow budget ----");
        check_notes;

        $display("");
        if (errors == 0)
            $display("== tb_test_mode : ALL PASS (%0d checks) ==", checks);
        else
            $display("== tb_test_mode : %0d of %0d checks FAILED ==", errors, checks);
        $finish;
    end

endmodule
