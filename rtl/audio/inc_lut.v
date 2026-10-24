//=============================================================================
// inc_lut.v  --  13-note equal-temperament phase increment table
//
//  inc = round(f_note * 2^32 / fs),  fs = 48 214.2857 Hz
//  (fs = 108 MHz / 2240 ; see frame_gen.v)
//
//  note_idx : 0 = C4 ... 12 = C5   (chromatic, A4 = 440 Hz)
//  Octave transposition is applied outside this table by shifting left
//  0/1/2 bits, so the largest increment produced downstream is
//      C5 (0x02C73CAF) * 4 (harmonic 4) * 4 (octave +2) = 0x2C73CAF0
//  which still fits in 32 bits.
//=============================================================================
`timescale 1ns / 1ps

module inc_lut (
    input  wire [4:0]  note_idx,
    output reg  [31:0] inc
);

    always @(*) begin
        case (note_idx)
            5'd0 : inc = 32'h01639E57;   // C4    261.626 Hz
            5'd1 : inc = 32'h0178C3C3;   // C#4   277.183 Hz
            5'd2 : inc = 32'h018F2B15;   // D4    293.665 Hz
            5'd3 : inc = 32'h01A6E772;   // D#4   311.127 Hz
            5'd4 : inc = 32'h01C00D20;   // E4    329.628 Hz
            5'd5 : inc = 32'h01DAB19B;   // F4    349.228 Hz
            5'd6 : inc = 32'h01F6EBA8;   // F#4   369.994 Hz
            5'd7 : inc = 32'h0214D364;   // G4    391.995 Hz
            5'd8 : inc = 32'h0234825C;   // G#4   415.305 Hz
            5'd9 : inc = 32'h025613A1;   // A4    440.000 Hz
            5'd10: inc = 32'h0279A3E2;   // A#4   466.164 Hz
            5'd11: inc = 32'h029F5181;   // B4    493.883 Hz
            5'd12: inc = 32'h02C73CAF;   // C5    523.251 Hz
            default: inc = 32'h01639E57;
        endcase
    end

endmodule
