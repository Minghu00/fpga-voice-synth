//============================================================================
//  wave_hist.v -- deep mono history buffer for the waveform page
//
//  1024 x 16 = 16 Kbit, which is exactly one GW2A 18 Kbit BSRAM block.
//
//  WHY THIS EXISTS
//  ---------------
//  The waveform page draws a start-triggered window: the leftmost column is
//  a rising zero crossing, and the next 479 columns are the samples that
//  follow it.  That only works if the crossing is at least 480 samples old
//  (the rest of the window has to have been written already) AND still
//  inside the buffer (otherwise the address has been overwritten and the
//  window shows unrelated data).
//
//  The usable trigger band is therefore  depth - 480  samples wide:
//
//      512  deep  ->  32 samples of band   (the old stereo wave_buf)
//     1024  deep  -> 544 samples of band   (this module)
//
//  A C4 has a period of 184 samples, so with a 32-sample band only about one
//  frame in six found a legal crossing and the rest fell back to a
//  free-running window -- the trace jumped phase every frame.  544 samples
//  covers a whole period down to C3, so every frame finds a crossing and the
//  picture stands still.
//
//  The stereo buffer stays as it is: the Lissajous page needs L and R of the
//  SAME instant, which a 32-bit word gives for free, and it only ever needs
//  512 samples of history.
//============================================================================
`timescale 1ns / 1ps

module wave_hist #(
    parameter integer AW = 10
)(
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [AW-1:0]         wr_addr,
    input  wire signed [15:0]    wr_data,
    input  wire [AW-1:0]         rd_addr,
    output reg  signed [15:0]    rd_data
);
    //  Read-during-write on the same address returns the OLD contents, which
    //  is what the scope fetch expects: it issues the address one clock
    //  before it needs the sample.
    reg signed [15:0] mem [0:(1<<AW)-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
