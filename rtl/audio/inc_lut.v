//=============================================================================
// inc_lut.v  --  29-note equal-temperament phase increment table
//
//  inc = round(f_note * 2^32 / fs),  fs = 48 214.2857 Hz
//  (fs = 108 MHz / 2240 ; see frame_gen.v)
//
//  note_idx : 0 = C4 ... 12 = C5 ... 24 = C6 ... 28 = E6
//             (chromatic, A4 = 440 Hz)
//
//  Who uses which part of the table:
//    0..12   the original one-octave keyboard layout (keymap8.v, NOTE_SCALE)
//    0..24   test_mode.v, which lays eight voices over two octaves so that
//            neighbouring spectral peaks are far enough apart to be counted
//            individually on a spectrum analyser
//    0..28   the "chord" pad layout of keymap8.v (NOTE_CHORD), an ascending
//            C major arpeggio C4 E4 G4 C5 E5 G5 C6 E6
//
//  Indices 0..24 keep exactly the values they had before this table was
//  widened; 25..28 were appended, so no existing behaviour changed.
//
//  OVERFLOW BUDGET
//  ---------------
//  Downstream the increment is shifted left by the octave (x1/x2/x4, in
//  osc_bank.v `targ_q <= pinc << oct`) and then by the harmonic index
//  (x1/x2/x3/x4).  Worst case the player can now produce is
//        E6 (0x0700347E) << 2 (octave) << 2 (harmonic) = 0x700347E0
//  which is 1.88e9 and still fits in 32 bits.  The retired comment here used
//  to claim C6 * 4 * 4 would overflow; that arithmetic was wrong (it is only
//  0x58E795E0 = 1.49e9), so the table can safely grow to E6.
//=============================================================================
`timescale 1ns / 1ps

module inc_lut (
    input  wire [4:0]  note_idx,
    output reg  [31:0] inc
);

    always @(*) begin
        case (note_idx)
            //---------------- octave 4 (C4 .. C5) ----------------
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
            //---------------- octave 5 (C#5 .. C6) --------------
            5'd13: inc = 32'h02F18787;   // C#5   554.365 Hz
            5'd14: inc = 32'h031E562B;   // D5    587.330 Hz
            5'd15: inc = 32'h034DCEE3;   // D#5   622.254 Hz
            5'd16: inc = 32'h03801A3F;   // E5    659.255 Hz
            5'd17: inc = 32'h03B56337;   // F5    698.456 Hz
            5'd18: inc = 32'h03EDD751;   // F#5   739.989 Hz
            5'd19: inc = 32'h0429A6C9;   // G5    783.991 Hz
            5'd20: inc = 32'h046904B8;   // G#5   830.609 Hz
            5'd21: inc = 32'h04AC2743;   // A5    880.000 Hz
            5'd22: inc = 32'h04F347C5;   // A#5   932.328 Hz
            5'd23: inc = 32'h053EA302;   // B5    987.767 Hz
            5'd24: inc = 32'h058E795E;   // C6   1046.502 Hz
            //---------------- octave 6 (C#6 .. E6) --------------
            //  Added for the "chord" pad layout of keymap8.v, which is an
            //  ascending C major arpeggio  C4 E4 G4 C5 E5 G5 C6 E6  and so
            //  needs indices above C6.  Nothing below index 25 changed value.
            5'd25: inc = 32'h05E30F0E;   // C#6  1108.731 Hz
            5'd26: inc = 32'h063CAC56;   // D6   1174.659 Hz
            5'd27: inc = 32'h069B9DC6;   // D#6  1244.508 Hz
            5'd28: inc = 32'h0700347E;   // E6   1318.510 Hz
            default: inc = 32'h01639E57; // C4
        endcase
    end

endmodule
