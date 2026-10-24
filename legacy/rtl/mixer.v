`timescale 1ns / 1ps

module mixer (
    input  wire signed [15:0] v0,
    input  wire signed [15:0] v1,
    input  wire signed [15:0] v2,
    input  wire signed [15:0] v3,
    output reg  signed [15:0] out
);

    wire signed [17:0] sum;

    assign sum = v0 + v1 + v2 + v3;

    always @(*) begin
        if (sum > 18'sd32767)
            out = 16'sd32767;
        else if (sum < -18'sd32768)
            out = -16'sd32768;
        else
            out = sum[15:0];
    end

endmodule
