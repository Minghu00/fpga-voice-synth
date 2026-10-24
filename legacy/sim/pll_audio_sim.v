`timescale 1ns / 1ps

module pll_audio (
    output reg clkout,
    output reg lock,
    input  wire clkin
);

    initial begin
        clkout = 1'b0;
        lock   = 1'b0;
        #100;
        lock = 1'b1;
    end

    always #7.4074 clkout = ~clkout;

endmodule
