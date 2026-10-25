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
    integer tab_bad0 = 0;
    integer tab_bad1 = 0;
    reg     wave_m   = 1'b0;
    reg     glide_m  = 1'b0;
    reg signed [5:0] vib_m = 6'sd0;

    always #4.6296 clk = ~clk;

    inc_lut u_exp_lut (.note_idx(NOTE), .inc(inc_exp));

    osc_bank #(.VOICES(16), .NCOMP(4)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .fc       (fc),
        .note_flat(note_flat),
        .timbre   (timbre),
        .oct      (oct),
        .wave_mode(wave_m),
        .glide_en (glide_m),
        .vib_d    (vib_m),
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
    // iverilog's %0s stops at the first NUL byte, and a string shorter than
    // the task argument lives right-justified with leading zeros.  Print the
    // name byte by byte instead so the whole message survives.
    task print_name;
        input [511:0] name;
        integer bi;
        begin
            for (bi = 63; bi >= 0; bi = bi - 1)
                if (name[bi*8 +: 8] != 8'd0)
                    $write("%c", name[bi*8 +: 8]);
        end
    endtask

    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond !== 1'b1) begin
                $write("FAIL  "); print_name(name); $write("\n");
                errors = errors + 1;
            end else begin
                $write("PASS  "); print_name(name); $write("\n");
            end
        end
    endtask

    task check_num;
        input [511:0] name;
        input integer got;
        input integer want;
        begin
            if (got !== want) begin
                $write("FAIL  "); print_name(name);
                $display(" : got %0d (%h) want %0d (%h)", got, got, want, want);
                errors = errors + 1;
            end else begin
                $write("PASS  "); print_name(name);
                $display(" : %0d", got);
            end
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

        //------------------------------------------------------------------
        // 6. wavetable selection
        //
        //    wave_mode = 0 must keep every component on table 0 (the old
        //    single-sine behaviour), and wave_mode = 1 must hand component c
        //    its own table c.  tab_q is registered with rom_a, so it is valid
        //    from sub1 of the slot onwards; sample it at sub3, which is where
        //    the ROM data is consumed.
        //------------------------------------------------------------------
        tab_bad0 = 0;
        tab_bad1 = 0;
        wave_m   = 1'b0;
        for (k = 0; k < 6000; k = k + 1) begin
            @(posedge clk);
            // only inside the oscillator window: above fc=1024 the bank is
            // doing the increment pre-compute and the slot pipeline is idle,
            // so tab_q legitimately holds the last slot's value.
            if (rst_n && (fc < 12'd1024) && (dut.sub == 4'd3)
                     && (dut.tab_q !== 2'd0))
                tab_bad0 = tab_bad0 + 1;
        end
        check("wave_mode=0 reads table 0 for every component", tab_bad0 == 0);

        wave_m = 1'b1;
        for (k = 0; k < 6000; k = k + 1) begin
            @(posedge clk);
            if (rst_n && (fc < 12'd1024) && (dut.sub == 4'd3)
                     && (dut.tab_q !== dut.cidx))
                tab_bad1 = tab_bad1 + 1;
        end
        check("wave_mode=1 gives component c table c", tab_bad1 == 0);
        wave_m = 1'b0;
        run_frames(2);

        //------------------------------------------------------------------
        // 6. glide (portamento)
        //    With glide_en = 0 the increment jumps to the new note at once.
        //    With glide_en = 1 it walks there exponentially, never overshoots,
        //    and still arrives.  Measured on the phase step of phase[0],
        //    which is exactly the increment the accumulator used.
        //------------------------------------------------------------------
        note_flat[4:0] = 5'd0;                     // C4
        glide_m = 1'b0;
        run_frames(2);
        p0 = dut.phase[0];
        run_frames(1);
        check_num("glide off: jump to the new note is immediate",
                  dut.phase[0] - p0, inc_exp);

        // now ask for one octave up WITH glide; the first frames must be
        // strictly between the old and the new increment
        glide_m = 1'b1;
        oct     = 2'd1;
        run_frames(1);
        p0 = dut.phase[0];
        run_frames(1);
        begin : glide_mid
            reg [31:0] step;
            step = dut.phase[0] - p0;
            check("glide on: first step lands between old and new pitch",
                  (step > inc_exp) && (step < (inc_exp << 1)));
        end

        // ... and it converges: the one-pole walks 1/64 of the remaining
        // distance per frame, so after 500 frames the residual is
        // (63/64)^500 ~ 0.04 % of a semitone-free octave.  Integer
        // truncation finally stalls it within 63 counts of the target,
        // so compare with a tolerance instead of exact equality.
        run_frames(900);
        p0 = dut.phase[0];
        run_frames(1);
        begin : glide_end
            reg [31:0] step;
            step = dut.phase[0] - p0;
            check("glide on: converges to the new increment",
                  (step > (inc_exp << 1) - 32'd4000) &&
                  (step <= (inc_exp << 1)));
            $display("      glide endpoint %0d (target %0d)", step, inc_exp << 1);
        end

        oct     = 2'd0;
        glide_m = 1'b0;
        run_frames(3);

        //------------------------------------------------------------------
        // 7. vibrato: vib_d = 0 must be a no-op, vib_d != 0 must move the
        //    increment by roughly inc/1024 * d and stay bounded
        //------------------------------------------------------------------
        vib_m = 6'sd0;
        run_frames(2);
        p0 = dut.phase[0];
        run_frames(1);
        check_num("vibrato off (vib_d = 0) leaves the increment untouched",
                  dut.phase[0] - p0, inc_exp);

        begin : vib_check
            reg [31:0] lo, hi, step;
            reg [31:0] expect_pk;
            integer    n;
            lo = 32'hFFFF_FFFF;  hi = 32'd0;
            // walk the modulation the way the LFO does: +DEPTH, 0, -DEPTH, 0
            for (n = 0; n < 40; n = n + 1) begin
                case (n % 4)
                    0: vib_m = 6'sd0;
                    1: vib_m = 6'sd18;
                    2: vib_m = 6'sd0;
                    default: vib_m = -6'sd18;
                endcase
                p0 = dut.phase[0];
                run_frames(1);
                step = dut.phase[0] - p0;
                if (step < lo) lo = step;
                if (step > hi) hi = step;
            end
            expect_pk = (inc_exp >> 10) * 32'd18;
            check("vibrato swings the increment both ways",
                  (hi > inc_exp) && (lo < inc_exp));
            check("vibrato peak detune stays within +DEPTH Q10",
                  (hi - inc_exp) <= expect_pk + (inc_exp >> 9));
            check("vibrato trough detune stays within -DEPTH Q10",
                  (inc_exp - lo) <= expect_pk + (inc_exp >> 9));
            $display("      vib step range %0d .. %0d (carrier %0d, peak dev %0d)",
                     lo, hi, inc_exp, expect_pk);
        end
        vib_m = 6'sd0;
        run_frames(3);

        if (errors == 0)
            $display("== tb_osc_bank : ALL PASS ==");
        else
            $display("== tb_osc_bank : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
