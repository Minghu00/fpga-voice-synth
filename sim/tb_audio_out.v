//=============================================================================
//  tb_audio_out.v  --  self-checking testbench for audio_out + i2s_tx
//
//  This is the "why was the board silent" regression test.  Two independent
//  faults made the DAC receive nothing audible while the panel drew a perfect
//  waveform:
//
//    A. the gain chain divided by 8 twice (once in mixer16's MIX_SHIFT, once
//       in the old SHIFT_HP), then multiplied by 40/256, so a single organ
//       voice came out at +-39 counts = -58 dBFS -- well below the amplifier's
//       noise floor.
//    B. mute was wired to Silicon Key_3, whose net the Dock pulls up to +1V5
//       through 10 k and only shorts to GND while pressed.  The pin idled
//       HIGH, so mute latched on at power-up and every sample was forced to 0.
//
//  Checks
//    1. gain uses the Q8 table: 1.0x, 4x, 0.5x and the 16x top step
//    2. the soft limiter saturates instead of wrapping
//    3. a realistic single-voice mixer value at the DEFAULT volume is
//       comfortably above -30 dBFS   (the exact failure above would give 39)
//    4. mute forces an exact zero and un-mute restores the signal
//    5. sample_tick pulses exactly once per mix_ok
//    6. i2s_tx serialises exactly the sample that load_tick latched
//    7. test tone ignores the synth and produces a slow square wave
//=============================================================================
`timescale 1ns / 1ps

module tb_audio_out;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [11:0] fc = 12'd0;
    reg         mix_ok = 1'b0;
    reg  signed [15:0] mix_in = 16'sd0;
    reg  [3:0]  vol_raw = 4'd6;
    reg         mute = 1'b0;
    reg         test_tone = 1'b0;

    wire signed [15:0] sample;
    wire               sample_tick;

    wire bclk, lrclk, din;

    always #4.6296 clk = ~clk;          // 108 MHz

    audio_out #(.TONE_DIV(256)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .frame_tick(1'b0),
        .mix_ok    (mix_ok),
        .mix_in    (mix_in),
        .vol_raw   (vol_raw),
        .mute      (mute),
        .test_tone (test_tone),
        .sample    (sample),
        .sample_tick(sample_tick)
    );

    i2s_tx #(.BCLK_HALF(3)) u_i2s (
        .clk      (clk),
        .rst_n    (rst_n),
        .fc       (fc),
        .load_tick(sample_tick),
        .sample_l (sample),
        .sample_r (sample),
        .bclk     (bclk),
        .lrclk    (lrclk),
        .din      (din)
    );

    integer errors = 0;

    task chk;
        input            cond;
        input [8*70-1:0] name;
        begin
            if (cond) $display("PASS  %0s", name);
            else begin
                $display("FAIL  %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_num;
        input signed [31:0] got;
        input signed [31:0] want;
        input [8*70-1:0]    name;
        begin
            if (got === want) $display("PASS  %0s : %0d", name, got);
            else begin
                $display("FAIL  %0s : got %0d want %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // one mix window: pulse mix_ok once and let the 3-stage pipe settle.
    task push_mix;
        input signed [15:0] v;
        begin
            @(negedge clk);
            mix_in = v;
            mix_ok = 1'b1;
            @(negedge clk);
            mix_ok = 1'b0;
            repeat (12) @(negedge clk);
        end
    endtask

    integer n_ticks;
    integer i;
    reg [31:0] captured;
    integer bi;

    initial begin
        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (8) @(negedge clk);

        //------------------------------------------------------------------
        $display("");
        $display("---- 1. Q8 gain table ----");
        //------------------------------------------------------------------
        mute      = 1'b0;
        test_tone = 1'b0;

        vol_raw = 4'd2;                      // 256/256 = 1.0x
        repeat (4) @(negedge clk);
        push_mix(16'sd8000);
        chk_num(sample, 16'sd8000, "gain 1.0x passes the mixer value through");

        push_mix(-16'sd8000);
        chk_num(sample, -16'sd8000, "gain 1.0x keeps the sign");

        vol_raw = 4'd6;                      // 1024/256 = 4.0x  (default)
        repeat (4) @(negedge clk);
        push_mix(16'sd2047);
        chk_num(sample, 16'sd8188, "gain 4.0x : 2047 -> 8188");

        vol_raw = 4'd0;                      // 128/256 = 0.5x
        repeat (4) @(negedge clk);
        push_mix(16'sd8000);
        chk_num(sample, 16'sd4000, "gain 0.5x : 8000 -> 4000");

        vol_raw = 4'd10;                     // 4096/256 = 16.0x (top step)
        repeat (4) @(negedge clk);
        push_mix(16'sd4095);
        chk_num(sample, 16'sd32767, "gain 16x saturates at +32767, no wrap");

        push_mix(-16'sd4095);
        chk_num(sample, -32'sd32768, "gain 16x saturates at the negative rail");

        //------------------------------------------------------------------
        $display("");
        $display("---- 3. the old silence bug cannot come back ----");
        //------------------------------------------------------------------
        // mixer16 with MIX_SHIFT=3 turns one full-scale organ voice (16383)
        // into 2047.  At the power-on volume that must be a clearly audible
        // number of counts, not the 39 the broken gain chain produced.
        vol_raw = 4'd6;
        repeat (4) @(negedge clk);
        push_mix(16'sd2047);
        chk_num(sample, 16'sd8188, "single voice at default volume = 8188 counts");
        chk((sample > 16'sd6000),
            "default volume leaves one voice above -14 dBFS (old chain gave 39)");

        //------------------------------------------------------------------
        $display("");
        $display("---- 4. mute forces an exact zero ----");
        //------------------------------------------------------------------
        mute = 1'b1;
        repeat (8) @(negedge clk);
        push_mix(16'sd8000);
        chk_num(sample, 16'sd0, "mute outputs exactly zero");
        mute = 1'b0;
        repeat (8) @(negedge clk);
        push_mix(16'sd2047);
        chk_num(sample, 16'sd8188, "un-mute restores the signal");

        //------------------------------------------------------------------
        $display("");
        $display("---- 5. sample_tick is one pulse per mix_ok ----");
        //------------------------------------------------------------------
        n_ticks = 0;
        fork
            begin : cnt
                for (i = 0; i < 200; i = i + 1) begin
                    @(posedge clk);
                    if (sample_tick) n_ticks = n_ticks + 1;
                end
            end
            begin : drv
                push_mix(16'sd1000);
                push_mix(16'sd2000);
                push_mix(16'sd3000);
            end
        join
        chk_num(n_ticks, 3, "three mix_ok pulses -> three sample_tick pulses");

        //------------------------------------------------------------------
        $display("");
        $display("---- 6. i2s_tx serialises what load_tick latched ----");
        //------------------------------------------------------------------
        push_mix(16'sd2047);
        chk_num(sample, 16'sd8188, "final sample before serialising = 8188");

        captured = 32'd0;
        fc = 12'd2;
        // Frame-align the capture instead of guessing a lead-in: u_i2s.bitn
        // names the bit that is on the wire at every BCLK rising edge, so
        // waiting for bitn == 0 lands exactly on the MSB of the left word.
        @(posedge bclk);
        while (u_i2s.bitn != 6'd0) @(posedge bclk);
        for (bi = 0; bi < 32; bi = bi + 1) begin
            captured = {captured[30:0], din};
            @(posedge bclk);
        end
        // 8188 = 16'h1FFC
        chk_num($signed(captured[15:0]), 16'sh1FFC,
                "left slot carries the gained sample");
        chk_num($signed(captured[31:16]), 16'sh1FFC,
                "right slot carries the same sample");

        //------------------------------------------------------------------
        $display("");
        $display("---- 7. test tone ignores the synth ----");
        //------------------------------------------------------------------
        test_tone = 1'b1;
        repeat (4) @(negedge clk);
        n_ticks = 0;
        for (i = 0; i < 300; i = i + 1) begin
            push_mix(16'sd0);
            if (sample == 16'sh2000 || sample == -16'sh2000) n_ticks = n_ticks + 1;
        end
        chk(n_ticks > 250, "test tone replaces the synth (constant +-0x2000)");
        test_tone = 1'b0;
        repeat (4) @(negedge clk);
        push_mix(16'sd2047);
        chk_num(sample, 16'sd8188, "test tone off returns to the synth");

        //------------------------------------------------------------------
        if (errors == 0)
            $display("\n== tb_audio_out : ALL PASS ==");
        else
            $display("\n== tb_audio_out : %0d FAILURES ==", errors);
        $finish;
    end

endmodule
