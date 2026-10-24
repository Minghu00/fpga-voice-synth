`timescale 1ns / 1ps

module key_ctrl #(
    parameter KEY_NUM     = 4,
    parameter CLK_FREQ    = 27_000_000,
    parameter DEBOUNCE_MS = 4
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [KEY_NUM-1:0] key_n,
    output wire [KEY_NUM-1:0] trig
);

    genvar g;
    generate
        for (g = 0; g < KEY_NUM; g = g + 1) begin : g_key
            key_toggle #(
                .CLK_FREQ    (CLK_FREQ),
                .DEBOUNCE_MS (DEBOUNCE_MS)
            ) u_key_toggle (
                .clk   (clk),
                .rst_n (rst_n),
                .key_n (key_n[g]),
                .trig  (trig[g])
            );
        end
    endgenerate

endmodule
