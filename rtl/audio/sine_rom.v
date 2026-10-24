//=============================================================================
// sine_rom.v  --  shared 1024 x 16-bit signed sine table
//
//  Contents of rtl/audio/sine_1024.mem are TWO'S COMPLEMENT SIGNED values
//      round(32767 * sin(2*pi*i/1024)),  i = 0 .. 1023
//  Verifying points:  i=0 -> 0000, i=256 -> 7FFF, i=512 -> 0000,
//                     i=768 -> 8001 (negative peak), i=1023 -> FF37
//
//  NOTE: the legacy table was an UNSIGNED, offset-by-32768 sine, which the
//  old synth_voice.v then consumed with $signed() -- that produced a
//  half-wave-rectified output with a large DC term.  The table has been
//  regenerated as signed, so read it directly.
//
//  $readmemh path is relative to the project root; both the Gowin flow
//  (gw_sh opened on *.gprj) and the iverilog flow (run from the project
//  root) resolve "rtl/audio/sine_1024.mem" correctly.  If the table is
//  ever moved again, this is the ONLY line that needs to change.
//=============================================================================
`timescale 1ns / 1ps

module sine_rom (
    input  wire        clk,
    input  wire [9:0]  addr,
    output reg  [15:0] data        // signed two's complement
);

    reg [15:0] rom [0:1023];

    initial begin
        $readmemh("rtl/audio/sine_1024.mem", rom);
    end

    always @(posedge clk) begin
        data <= rom[addr];
    end

endmodule
