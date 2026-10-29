//=============================================================================
// adsr.v  --  per-voice AD / ADSR envelope generator
//
//  en is asserted for exactly one clock at the start of every audio sample
//  (fs = 48 214.2857 Hz), so every *_STEP below is "env counts per sample".
//
//  Default steps give a plucked / struck envelope -- the note decays all the
//  way to silence while the key is still held:
//      attack  65535 / 340 =   193 samples =    4.0 ms
//      decay   65535 /   1 = 65535 samples = 1359 ms   -> silence
//      release 65535 /   6 = 10923 samples =  226.5 ms
//      sustain level 0  (decay never parks on a plateau)
//
//  A non-zero SUSTAIN still works and parks the envelope on that plateau, so a
//  拨奏 / 钢琴 / 弦乐 / 管风琴 preset can be selected by passing different
//  values without touching this code.
//
//  Why the default is 0: two sustained pure tones modulate 100 % at |f1-f2|,
//  which is heard as trembling.  With a decaying envelope the beating rides on
//  a falling amplitude and reads as a struck chord instead.
//=============================================================================
`timescale 1ns / 1ps

module adsr #(
    parameter [15:0] ATT_STEP = 16'd340,       // count/sample during attack
    parameter [15:0] DEC_STEP = 16'd1,         // count/sample during decay
    parameter [15:0] REL_STEP = 16'd6,         // count/sample during release
    parameter [15:0] SUSTAIN  = 16'd0          // sustain level (0 = plucked)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // one-clk sample strobe
    input  wire        gate,        // key held
    output reg  [15:0] env,
    output wire        active       // voice still audible
);

    localparam [15:0] MAX_ENV = 16'hFFFF;

    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_ATT  = 3'd1;
    localparam [2:0] S_DEC  = 3'd2;
    localparam [2:0] S_SUS  = 3'd3;
    localparam [2:0] S_REL  = 3'd4;

    reg [2:0] state;

    assign active = (state != S_IDLE) || (env != 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            env   <= 16'd0;
        end else if (en) begin
            case (state)
                S_IDLE: begin
                    env <= 16'd0;
                    if (gate)
                        state <= S_ATT;
                end

                S_ATT: begin
                    if (!gate) begin
                        state <= S_REL;
                    end else if (env > MAX_ENV - ATT_STEP) begin
                        env   <= MAX_ENV;
                        state <= S_DEC;
                    end else begin
                        env <= env + ATT_STEP;
                    end
                end

                S_DEC: begin
                    if (!gate) begin
                        state <= S_REL;
                    end else if (env <= SUSTAIN + DEC_STEP) begin
                        env   <= SUSTAIN;
                        state <= S_SUS;
                    end else begin
                        env <= env - DEC_STEP;
                    end
                end

                S_SUS: begin
                    if (!gate) begin
                        state <= S_REL;
                    end else begin
                        env <= SUSTAIN;
                    end
                end

                S_REL: begin
                    // re-strike while still releasing -> attack again
                    if (gate) begin
                        state <= S_ATT;
                    end else if (env <= REL_STEP) begin
                        env   <= 16'd0;
                        state <= S_IDLE;
                    end else begin
                        env <= env - REL_STEP;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
