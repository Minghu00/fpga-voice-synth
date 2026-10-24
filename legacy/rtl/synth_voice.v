`timescale 1ns / 1ps

module synth_voice (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire [1:0]         note_idx,
    input  wire               gate,
    input  wire [15:0]        vel,
    output wire signed [15:0] audio
);

    wire [31:0] tw;
    wire [31:0] phase;
    wire [15:0] wave;
    wire [15:0] env;

    note_lut u_note_lut (
        .idx (note_idx),
        .tw  (tw)
    );

    phase_acc u_phase_acc (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .inc   (tw),
        .phase (phase)
    );

    sine_rom u_sine_rom (
        .clk  (clk),
        .addr (phase[31:22]),
        .data (wave)
    );

    adsr u_adsr (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .gate  (gate),
        .env   (env)
    );

    wire [31:0] vol32;
    wire [15:0] vol;
    wire signed [31:0] prod;

    assign vol32 = env * vel;
    assign vol   = vol32[31:16];
    assign prod  = $signed(wave) * $signed({1'b0, vol});
    assign audio = prod[31:16];

endmodule
