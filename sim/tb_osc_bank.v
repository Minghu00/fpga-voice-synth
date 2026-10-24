//=============================================================================
// tb_osc_bank.v  --  self-checking testbench for the 64-oscillator bank
//
//  1. each of the 4 harmonics of one voice owns an independent 32-bit phase
//     accumulator running at 1x / 2x / 3x / 4x the fundamental
//  2. one octave up doubles the fundamental increment
//  3. the measured tone frequency matches inc * fs / 2^32
//  4. a pure organ tone is centred, symmetric and does not clip
//  5. switching to the square timbre adds harmonic energy (bigger peak)
//
//  All observations are taken on the falling clock edge, so every
//  non-blocking update has already settled and there is no sampling race.
//  No VCD is written: the run covers millions of clocks.
//=============================================================================
`timescale 1ns / 1ps

module tb_osc_bank;

    // NOTE must stay inside 0..24 now that inc_lut.v actually covers two
    // octaves.  It used to be 5'd24 and fell through to the `default` (C4)
    // arm of the old 13-note table; index 24 is a real C6 nowadays.
    localparam [4:0] NOTE = 5'd0;           // C4 = 261.63 Hz

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg  [11:0] fc    = 12'd0;
    reg  [79:0] note_flat = 80'd0;          // 16 x 5 bit note index
    reg  [1:0]  timbre = 2'd0;
    reg  [1:0]  oct    = 2'd0;

    wire [255:0] raw_flat;
    wire [31:0]  inc_exp;

    integer errors = 0;
    integer i;

    always #4.6296 clk = ~clk;

    inc_lut u_exp_lut (.note_idx(NOTE), .inc(inc_exp));

    osc_bank #(.VOICES(16), .NCOMP(4)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .fc       (fc),
        .note_flat(note_flat),
        .timbre   (timbre),
        .oct      (oct),
        .raw_flat (raw_flat)
    );

    always @(posedge clk) begin
        if (!rst_n) fc <= 12'd0;
        else if (fc == 12'd2239) fc <= 12'd0;
        else fc <= fc + 12'd1;
    end

    //------------------------------------------------------------------
    // helpers
    //------------------------------------------------------------------
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

    task check_num;
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got !== want) begin
                $display("FAIL  %0s : got %0d (%h) want %0d (%h)",
                         name, got, got, want, want);
                errors = errors + 1;
            end else
                $display("PASS  %0s : %0d", name, got);
        end
    endtask

    // advance to the next fc == 0, then run exactly n whole frames
    integer fcnt = 0;
    integer ftarget;

    always @(posedge clk)
        if (rst_n && (fc == 12'd2239))
            fcnt <= fcnt + 1;

    task run_frames;
        input integer n;
        begin
            @(negedge clk);
            ftarget = fcnt + n;
            while (fcnt < ftarget) @(negedge clk);
        end
    endtask

    // stop at fc == 120 of the next frame and return voice 0's raw sample
    reg signed [15:0] samp;
    task sample_frame;
        begin
            @(negedge clk);
            while (fc != 12'd0) @(negedge clk);
            while (fc != 12'd120) @(negedge clk);
            samp = $signed(raw_flat[15:0]);
        end
    endtask

    //------------------------------------------------------------------
    // measurement results
    //------------------------------------------------------------------
    real      fs;
    real      f_meas;
    real      f_exp;

    integer   k;
    integer   xc;
    integer   t_start;
    integer   t_end;
    integer   maxv;
    integer   minv;
    reg signed [15:0] prev_s;

    reg [31:0] p0, p1, p2, p3;

    initial begin
        fs = 108000000.0 / 2240.0;          // 48214.2857 Hz

        #200 rst_n = 1'b1;

        for (i = 0; i < 16; i = i + 1)
            note_flat[i*5 +: 5] = NOTE;

        timbre = 2'd0;                       // organ = pure sine
        oct    = 2'd0;

        $display("inc_exp = %h (%0d)", inc_exp, inc_exp);

        //------------------------------------------------------------------
        // 1. independent phase accumulators, 1x / 2x / 3x / 4x
        //    (inc_org is pre-computed in the tail of the frame, so one
        //     settling frame is needed after a note change)
        //------------------------------------------------------------------
        run_frames(2);
        p0 = dut.phase[0]; p1 = dut.phase[1];
        p2 = dut.phase[2]; p3 = dut.phase[3];
        run_frames(1);
        check_num("comp0 phase += inc",   dut.phase[0] - p0, inc_exp);
        check_num("comp1 phase += 2*inc", dut.phase[1] - p1, inc_exp << 1);
        check_num("comp2 phase += 3*inc", dut.phase[2] - p2, (inc_exp << 1) + inc_exp);
        check_num("comp3 phase += 4*inc", dut.phase[3] - p3, inc_exp << 2);

        //------------------------------------------------------------------
        // 2. octave up doubles the fundamental increment
        //------------------------------------------------------------------
        oct = 2'd1;
        run_frames(2);
        p0  = dut.phase[0];
        run_frames(1);
        check_num("oct+1 doubles increment", dut.phase[0] - p0, inc_exp << 1);
        oct = 2'd0;
        run_frames(1);

        //------------------------------------------------------------------
        // 3 + 4. frequency, symmetry and peak of the organ tone
        //------------------------------------------------------------------
        xc    = 0;
        t_start = 0;
        t_end = 0;
        maxv  = -40000;
        minv  =  40000;
        prev_s = 0;

        for (k = 0; (k < 20000) && (xc < 21); k = k + 1) begin
            sample_frame;
            if (samp > maxv) maxv = samp;
            if (samp < minv) minv = samp;
            if ((prev_s <= 0) && (samp > 0)) begin
                if (xc == 0) t_start = k;
                if (xc == 20) t_end = k;
                xc = xc + 1;
            end
            prev_s = samp;
        end

        f_exp  = inc_exp * fs / 4294967296.0;
        f_meas = 20.0 * fs / ((t_end - t_start) * 1.0);

        $display("      inc=%0d  f_exp=%0.3f Hz  f_meas=%0.3f Hz  (%0d periods over %0d samples)",
                 inc_exp, f_exp, f_meas, 20, t_end - t_start);
        check("20 rising zero crossings observed", xc >= 21);
        check("measured pitch within 1 %", (f_meas > f_exp * 0.99) && (f_meas < f_exp * 1.01));

        $display("      organ peak +%0d / %0d", maxv, minv);
        check("organ peak near +16383", (maxv > 16000) && (maxv <= 16384));
        check("organ peak near -16383", (minv < -16000) && (minv >= -16384));

        //------------------------------------------------------------------
        // 5. square timbre adds harmonic energy
        //------------------------------------------------------------------
        timbre = 2'd1;
        maxv   = -40000;
        minv   =  40000;
        for (k = 0; k < 300; k = k + 1) begin
            sample_frame;
            if (samp > maxv) maxv = samp;
            if (samp < minv) minv = samp;
        end
        $display("      square peak +%0d / %0d", maxv, minv);
        check("square timbre peak exceeds sine peak", maxv > 16884);

        if (errors == 0)
            $display("== tb_osc_bank : ALL PASS ==");
        else
            $display("== tb_osc_bank : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
