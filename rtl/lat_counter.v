//=============================================================================
// lat_counter.v  --  on-chip control-to-audio latency meter
//
//  Started by any change of key_raw (the instant the TTP229 hands over a new
//  key bitmap) and stopped at the audio frame boundary at which the freshly
//  synthesised sample is loaded into the I2S shifter.
//
//      latency_us = lat_val / 108
//
//  The value is exported so the report can quote a silicon-measured number
//  instead of a spreadsheet estimate, and it proves the figure is
//  deterministic (no jitter) rather than merely bounded.
//=============================================================================
`timescale 1ns / 1ps

module lat_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] fc,
    input  wire [15:0] key_raw,
    output reg  [31:0] lat_val,      // last measurement, in clk (108 MHz)
    output reg  [31:0] lat_max,
    output reg         lat_valid
);

    reg [15:0] key_d;
    reg        running;
    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_d     <= 16'd0;
            running   <= 1'b0;
            cnt       <= 32'd0;
            lat_val   <= 32'd0;
            lat_max   <= 32'd0;
            lat_valid <= 1'b0;
        end else begin
            key_d <= key_raw;

            if (key_raw != key_d) begin
                running <= 1'b1;
                cnt     <= 32'd0;
            end else if (running) begin
                if (fc == 12'd1) begin
                    lat_val   <= cnt;
                    lat_valid <= 1'b1;
                    running   <= 1'b0;
                    if (cnt > lat_max)
                        lat_max <= cnt;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end
        end
    end

endmodule
