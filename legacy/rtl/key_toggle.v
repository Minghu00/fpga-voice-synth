`timescale 1ns / 1ps

module key_toggle #(
    parameter CLK_FREQ    = 27_000_000,
    parameter DEBOUNCE_MS = 4
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,
    output reg  trig
);

    localparam integer CNT_MAX = (CLK_FREQ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_W   = $clog2(CNT_MAX + 1);

    reg [1:0]       sync;
    reg             stable;
    reg [CNT_W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync   <= 2'b11;
            stable <= 1'b1;
            cnt    <= {CNT_W{1'b0}};
            trig   <= 1'b0;
        end else begin
            sync <= {sync[0], key_n};

            if (sync[1] == stable) begin
                cnt <= {CNT_W{1'b0}};
            end else if (cnt == CNT_MAX[CNT_W-1:0]) begin
                stable <= sync[1];
                cnt    <= {CNT_W{1'b0}};
                if (sync[1] == 1'b1)
                    trig <= ~trig;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
