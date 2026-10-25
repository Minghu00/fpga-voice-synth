//============================================================================
//  wave_buf.v -- 512 x 16 x 2 audio history buffer (stereo, one BSRAM)
//
//  Written once per audio frame (48.214 kHz), read by the pixel pipeline.
//  One write port + one registered read port, 32 bit wide = a single
//  true dual-port BSRAM (512 x 32 = 16 Kbit, fits one GW2A 18 Kbit block).
//
//  Both channels share the write address and the read address, so the left
//  and right samples of the same instant are always presented together --
//  which is exactly what the Lissajous page needs (X = L, Y = R of the same
//  sample).
//
//  Read-during-write on the same address returns the OLD contents, which is
//  exactly what the scope drawing wants.
//============================================================================
`timescale 1ns / 1ps

module wave_buf (
    input  wire        clk,
    input  wire        wr_en,
    input  wire [8:0]  wr_addr,
    input  wire [15:0] wr_data_l,
    input  wire [15:0] wr_data_r,
    input  wire [8:0]  rd_addr,
    output reg  [15:0] rd_data_l,
    output reg  [15:0] rd_data_r
);
    // Two 16-bit planes in one array of 32-bit words keeps the read port
    // single and the latency at exactly one clock.
    reg [31:0] mem [0:511];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= {wr_data_r, wr_data_l};
        {rd_data_r, rd_data_l} <= mem[rd_addr];
    end

endmodule
