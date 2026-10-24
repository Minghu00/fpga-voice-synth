//=============================================================================
// pll_sys_sim.v  --  behavioural stand-in for rPLL (simulation only)
//
//  Compile this INSTEAD of rtl/pll_sys.v when simulating, because the Gowin
//  rPLL primitive is a black box for iverilog.
//      clk_sys = 108 MHz  (period 9.259259 ns)
//      locked  = 1 after 200 ns
//=============================================================================
`timescale 1ns / 1ps

module pll_sys (
    input  wire clk27,
    input  wire rst_n,
    output reg  clk_sys,
    output reg  locked
);

    initial begin
        clk_sys = 1'b0;
        locked  = 1'b0;
        #200 locked = 1'b1;
    end

    always #4.6296 clk_sys = ~clk_sys;    // 108 MHz

endmodule
