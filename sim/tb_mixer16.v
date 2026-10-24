//=============================================================================
// tb_mixer16.v  --  self-checking testbench for mixer16
//
//  Walks fc through the 64-clk mix window (1088..1151) and checks the
//  limited mixdown value.
//
//      1. one voice  : 32767 * 65535 >> 16 >> 4  = 2047
//      2. 16 voices  : must NOT clip                = 32766
//      3. negative   : full-scale negative voice    = 0x8000
//      4. silent     : env = 0                      = 0
//      5. MIX_SHIFT=0 instance must hit the limiter = 0x7FFF
//=============================================================================
`timescale 1ns / 1ps

module tb_mixer16;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg  [11:0] fc    = 12'd0;

    reg [15:0] raw [0:15];
    reg [15:0] env [0:15];

    reg [255:0] raw_flat;
    reg [255:0] env_flat;

    wire        mix_ph = (fc >= 12'd1088) && (fc < 12'd1152);
    wire [15:0] out;
    wire [15:0] out0;

    integer errors = 0;
    integer i;

    always #4.6296 clk = ~clk;

    always @* begin
        for (i = 0; i < 16; i = i + 1) begin
            raw_flat[i*16 +: 16] = raw[i];
            env_flat[i*16 +: 16] = env[i];
        end
    end

    mixer16 #(.VOICES(16), .MIX_SHIFT(4)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .fc      (fc),
        .mix_ph  (mix_ph),
        .raw_flat(raw_flat),
        .env_flat(env_flat),
        .out     (out)
    );

    // second instance with no headroom shift, to exercise the limiter
    mixer16 #(.VOICES(16), .MIX_SHIFT(0)) dut0 (
        .clk     (clk),
        .rst_n   (rst_n),
        .fc      (fc),
        .mix_ph  (mix_ph),
        .raw_flat(raw_flat),
        .env_flat(env_flat),
        .out     (out0)
    );

    task run_mix;
        integer k;
        begin
            for (k = 0; k < 64; k = k + 1) begin
                @(negedge clk);
                fc = 12'd1088 + k;
            end
            @(negedge clk);
            fc = 12'd0;
            @(negedge clk);
        end
    endtask

    task clear_voices;
        integer k;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                raw[k] = 16'd0;
                env[k] = 16'd0;
            end
        end
    endtask

    task check;
        input [255:0] name;
        input [15:0]  got;
        input [15:0]  want;
        begin
            if (got !== want) begin
                $display("FAIL  %0s : got %h want %h", name, got, want);
                errors = errors + 1;
            end else
                $display("PASS  %0s : %h", name, got);
        end
    endtask

    initial begin
        $dumpfile("sim/tb_mixer16.vcd");
        $dumpvars(0, tb_mixer16);

        clear_voices();
        #200 rst_n = 1'b1;

        // 1. single full-scale voice
        clear_voices();
        raw[0] = 16'h7FFF;  env[0] = 16'hFFFF;
        run_mix;
        check("single voice >>4", out, 16'd2047);

        // 2. all 16 voices at full scale -- must not clip
        clear_voices();
        for (i = 0; i < 16; i = i + 1) begin
            raw[i] = 16'h7FFF;
            env[i] = 16'hFFFF;
        end
        run_mix;
        check("16 voices no clipping", out, 16'd32766);

        // 3. all 16 voices at full-scale negative
        clear_voices();
        for (i = 0; i < 16; i = i + 1) begin
            raw[i] = 16'h8000;
            env[i] = 16'hFFFF;
        end
        run_mix;
        check("16 voices negative", out, 16'h8000);

        // 4. envelope closed -> silence even with a full-scale waveform
        clear_voices();
        for (i = 0; i < 16; i = i + 1)
            raw[i] = 16'h7FFF;
        run_mix;
        check("all envelopes closed", out, 16'h0000);

        // 5. limiter in the MIX_SHIFT=0 instance
        clear_voices();
        for (i = 0; i < 4; i = i + 1) begin
            raw[i] = 16'h7FFF;
            env[i] = 16'hFFFF;
        end
        run_mix;
        check("limiter clips at +full scale", out0, 16'h7FFF);

        // 6. envelope scaling is linear: half envelope -> half output
        clear_voices();
        raw[0] = 16'h7FFF;  env[0] = 16'h8000;
        run_mix;
        check("half envelope", out, 16'd1023);

        if (errors == 0)
            $display("== tb_mixer16 : ALL PASS ==");
        else
            $display("== tb_mixer16 : %0d FAILURE(S) ==", errors);

        $finish;
    end

endmodule
