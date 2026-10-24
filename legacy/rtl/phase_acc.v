`timescale 1ns / 1ps

module phase_acc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [31:0] inc,
    output reg  [31:0] phase
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase <= 32'd0;
        else if (en)
            phase <= phase + inc;
    end

endmodule
