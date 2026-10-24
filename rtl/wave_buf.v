//============================================================================
//  wave_buf.v -- 512 x 16 audio history buffer (one BSRAM)
//
//  Written once per audio frame (48.214 kHz), read by the pixel pipeline.
//  One write port + one registered read port = a single true dual-port
//  BSRAM (512 x 16 = 8 Kbit, fits a GW2A 9 Kbit block).
//
//  Read-during-write on the same address returns the OLD contents, which is
//  exactly what the scope drawing wants.
//============================================================================
`timescale 1ns / 1ps

module wave_buf (
    input  wire        clk,
    input  wire        wr_en,
    input  wire [8:0]  wr_addr,
    input  wire [15:0] wr_data,
    input  wire [8:0]  rd_addr,
    output reg  [15:0] rd_data
);
    reg [15:0] mem [0:511];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
