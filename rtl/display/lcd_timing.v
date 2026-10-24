//============================================================================
//  lcd_timing.v -- 480x272 / 9 MHz RGB panel timing
//
//  Pixel clock: sys_clk / DIV = 108 MHz / 12 = 9.000 MHz
//  Horizontal : H_ACT 480 + H_FP 2 + H_SYNC 41 + H_BP 2 = 525  -> 58.33 us
//  Vertical   : V_ACT 272 + V_FP 2 + V_SYNC 10 + V_BP 2 = 286  -> 16.683 ms
//  Frame rate : 9e6 / (525*286) = 59.94 Hz
//
//  Both sync pulses are active LOW (HS_POL = 0, VS_POL = 0), matching the
//  Sipeed 480x272_4.3inch_lcd example this panel was verified against.
//
//  x/y advance on pix_tick (phase DIV-2 of the pixel period).  The data
//  path is allowed DIV cycles per pixel, which is what lets the waveform
//  RAM be read twice per pixel on a single read port.
//============================================================================
`timescale 1ns / 1ps

module lcd_timing #(
    parameter integer DIV    = 12,
    parameter integer H_ACT  = 480,
    parameter integer H_FP   = 2,
    parameter integer H_SYNC = 41,
    parameter integer H_BP   = 2,
    parameter integer V_ACT  = 272,
    parameter integer V_FP   = 2,
    parameter integer V_SYNC = 10,
    parameter integer V_BP   = 2
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg  [3:0] ph,          // sub-pixel phase 0 .. DIV-1
    output reg        pix_tick,    // one pulse per pixel (phase DIV-2)
    output reg  [9:0] x,
    output reg  [9:0] y
);
    localparam integer H_TOT = H_ACT + H_FP + H_SYNC + H_BP;   // 525
    localparam integer V_TOT = V_ACT + V_FP + V_SYNC + V_BP;   // 286

    always @(posedge clk) begin
        if (!rst_n) begin
            ph       <= 4'd0;
            pix_tick <= 1'b0;
            x        <= 10'd0;
            y        <= 10'd0;
        end else begin
            if (ph == DIV - 1) begin
                ph       <= 4'd0;
                pix_tick <= 1'b0;
            end else begin
                ph       <= ph + 4'd1;
                pix_tick <= (ph == DIV - 2);
            end

            if (pix_tick) begin
                if (x == H_TOT - 1) begin
                    x <= 10'd0;
                    if (y == V_TOT - 1)
                        y <= 10'd0;
                    else
                        y <= y + 10'd1;
                end else begin
                    x <= x + 10'd1;
                end
            end
        end
    end

endmodule
