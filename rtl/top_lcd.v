//=============================================================================
//  top_lcd.v -- L C D   O N L Y   bring-up top level
//
//  No audio, no touch.  Just the 480x272 RGB panel, so that the display path
//  can be verified on its own before anything else is wired up.
//
//  Screen layout (480 x 272, landscape, 16 columns of 30 px):
//
//    y   0.. 15   16 top ruler blocks, one bright block steps L -> R
//    y  16.. 47   grey ramp, 32 steps (one step every 15 px)
//    y  48.. 95   red   ramp
//    y  96..143   green ramp
//    y 144..191   blue  ramp
//    y 192..223   16 reference colour blocks
//    y 224..271   16 animated bars (triangle wave, one phase per column)
//
//  A bright white vertical line sweeps one column per frame, which makes it
//  obvious at a glance that the picture is live and not a frozen frame.
//=============================================================================
`timescale 1ns / 1ps

module top_lcd #(
    // panel geometry, 480x272 @ 9 MHz
    parameter integer DIV     = 12,     // 108 MHz / 12 = 9 MHz pixel clock
    parameter integer H_ACT   = 480,
    parameter integer H_FP    = 2,
    parameter integer H_SYNC  = 41,
    parameter integer H_BP    = 2,
    parameter integer V_ACT   = 272,
    parameter integer V_FP    = 2,
    parameter integer V_SYNC  = 10,
    parameter integer V_BP    = 2
)(
    input  wire       clk27,
    input  wire       rst_n,

    output wire       lcd_dclk,
    output reg        lcd_hs,
    output reg        lcd_vs,
    output reg        lcd_de,
    output reg  [4:0] lcd_r,
    output reg  [5:0] lcd_g,
    output reg  [4:0] lcd_b
);

    //------------------------------------------------------------------
    // clock and reset
    //------------------------------------------------------------------
    wire clk_sys;
    wire locked;

    pll_sys u_pll (
        .clk27  (clk27),
        .rst_n  (rst_n),
        .clk_sys(clk_sys),
        .locked (locked)
    );

    wire arst_n = rst_n & locked;

    reg [1:0] rsync;
    always @(posedge clk_sys or negedge arst_n) begin
        if (!arst_n) rsync <= 2'b00;
        else         rsync <= {rsync[0], 1'b1};
    end
    wire srst_n = rsync[1];

    //------------------------------------------------------------------
    // panel timing
    //------------------------------------------------------------------
    wire [3:0] ph;
    wire       pix_tick;
    wire [9:0] x;
    wire [9:0] y;

    lcd_timing #(
        .DIV   (DIV),
        .H_ACT (H_ACT),
        .H_FP  (H_FP),
        .H_SYNC(H_SYNC),
        .H_BP  (H_BP),
        .V_ACT (V_ACT),
        .V_FP  (V_FP),
        .V_SYNC(V_SYNC),
        .V_BP  (V_BP)
    ) u_tmg (
        .clk     (clk_sys),
        .rst_n   (srst_n),
        .ph      (ph),
        .pix_tick(pix_tick),
        .x       (x),
        .y       (y)
    );

    //------------------------------------------------------------------
    // one-shot-per-frame counters
    //   sweep : which column carries the white line, advances every frame
    //   anim  : free running animation time base (8 bit)
    //------------------------------------------------------------------
    wire frame_start = pix_tick && (x == 10'd0) && (y == 10'd0);

    reg [9:0] sweep;
    reg [7:0] anim;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            sweep <= 10'd0;
            anim  <= 8'd0;
        end else if (frame_start) begin
            sweep <= (sweep == 10'd479) ? 10'd0 : sweep + 10'd1;
            anim  <= anim + 8'd1;
        end
    end

    //------------------------------------------------------------------
    // pixel pipeline
    //   ph 5 : latch x / y and everything derived from them
    //   ph 8 : pick the colour
    //   ph 10: drive the pins together with de / hs / vs
    //------------------------------------------------------------------
    reg [9:0] x_q, y_q;
    reg [9:0] sweep_q;
    reg [7:0] anim_q;

    wire [20:0] bar_m = x * 21'd4369;      // x / 15 -> 0..31   (65536/15)
    wire [20:0] box_m = x * 21'd2185;      // x / 30 -> 0..15   (65536/30)

    reg [4:0] bar_q;                       // ramp step index
    reg [3:0] box_q;                       // 30 px column index 0..15

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            x_q <= 10'd0;  y_q <= 10'd0;
            sweep_q <= 10'd0;  anim_q <= 8'd0;
            bar_q <= 5'd0;  box_q <= 4'd0;
        end else if (ph == 4'd5) begin
            x_q     <= x;
            y_q     <= y;
            sweep_q <= sweep;
            anim_q  <= anim;
            bar_q   <= bar_m[20:16];
            box_q   <= box_m[19:16];
        end
    end

    //------------------------------------------------------------------
    // 16 reference colours for the block row: {r[4:0], g[5:0], b[4:0]}
    //------------------------------------------------------------------
    function [15:0] blk_col;
        input [3:0] n;
        begin
            case (n)
                4'd0 : blk_col = {5'd0,  6'd0,  5'd0 };   // black
                4'd1 : blk_col = {5'd31, 6'd0,  5'd0 };   // red
                4'd2 : blk_col = {5'd0,  6'd63, 5'd0 };   // green
                4'd3 : blk_col = {5'd0,  6'd0,  5'd31};   // blue
                4'd4 : blk_col = {5'd31, 6'd63, 5'd0 };   // yellow
                4'd5 : blk_col = {5'd31, 6'd0,  5'd31};   // magenta
                4'd6 : blk_col = {5'd0,  6'd63, 5'd31};   // cyan
                4'd7 : blk_col = {5'd31, 6'd63, 5'd31};   // white
                4'd8 : blk_col = {5'd16, 6'd0,  5'd0 };   // dark red
                4'd9 : blk_col = {5'd0,  6'd31, 5'd0 };   // dark green
                4'd10: blk_col = {5'd0,  6'd0,  5'd16};   // dark blue
                4'd11: blk_col = {5'd16, 6'd31, 5'd16};   // grey
                4'd12: blk_col = {5'd8,  6'd16, 5'd24};   // steel
                4'd13: blk_col = {5'd24, 6'd16, 5'd8 };   // brown
                4'd14: blk_col = {5'd31, 6'd31, 5'd0 };   // amber
                default: blk_col = {5'd0, 6'd31, 5'd31};  // aqua
            endcase
        end
    endfunction

    wire [15:0] blk = blk_col(box_q);

    //------------------------------------------------------------------
    // bar animation
    //   phase = anim + column * 16   -> one triangle wave per column,
    //   neighbouring columns are 16 counts (1/8 of a cycle) apart.
    //------------------------------------------------------------------
    wire [7:0] bar_phase = anim_q + {box_q, 4'b0};
    wire [7:0] bar_tri   = bar_phase[7] ? ~bar_phase : bar_phase;
    wire [5:0] bar_hgt   = (bar_tri[6:1] > 6'd47) ? 6'd47 : bar_tri[6:1];

    // row distance from the bottom of the bar band (y 271 -> 0, y 224 -> 47)
    wire [9:0] row_up = 10'd271 - y_q;
    wire       bar_lit = (row_up < {4'd0, bar_hgt});

    //------------------------------------------------------------------
    // colour lookup
    //------------------------------------------------------------------
    reg [4:0] nr;
    reg [5:0] ng;
    reg [4:0] nb;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            nr <= 5'd0; ng <= 6'd0; nb <= 5'd0;
        end else if (ph == 4'd8) begin
            // ---- top ruler: 16 blocks, one of them bright ----
            if (y_q < 10'd16) begin
                if (box_q == anim_q[3:0]) begin
                    nr <= 5'd31; ng <= 6'd63; nb <= 5'd31;   // bright white
                end else begin
                    nr <= 5'd4;  ng <= 6'd8;  nb <= 5'd4;    // dark grey
                end
            end
            // ---- grey ramp ----
            else if (y_q < 10'd48) begin
                nr <= bar_q;  ng <= {bar_q, 1'b0};  nb <= bar_q;
            end
            // ---- red ramp ----
            else if (y_q < 10'd96) begin
                nr <= bar_q;  ng <= 6'd0;           nb <= 5'd0;
            end
            // ---- green ramp ----
            else if (y_q < 10'd144) begin
                nr <= 5'd0;   ng <= {bar_q, 1'b0};  nb <= 5'd0;
            end
            // ---- blue ramp ----
            else if (y_q < 10'd192) begin
                nr <= 5'd0;   ng <= 6'd0;           nb <= bar_q;
            end
            // ---- 16 reference colour blocks ----
            else if (y_q < 10'd224) begin
                nr <= blk[15:11];  ng <= blk[10:5];  nb <= blk[4:0];
            end
            // ---- animated bars ----
            else begin
                if (bar_lit) begin
                    nr <= 5'd2;   ng <= 6'd63;  nb <= 5'd10;
                end else begin
                    nr <= 5'd1;   ng <= 6'd6;   nb <= 5'd3;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // output register: the sweep line overlays the final image
    //------------------------------------------------------------------
    wire hsync_n = ~((x >= (H_ACT + H_FP)) && (x < (H_ACT + H_FP + H_SYNC)));
    wire vsync_n = ~((y >= (V_ACT + V_FP)) && (y < (V_ACT + V_FP + V_SYNC)));

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            lcd_r  <= 5'd0;
            lcd_g  <= 6'd0;
            lcd_b  <= 5'd0;
            lcd_de <= 1'b0;
            lcd_hs <= 1'b1;
            lcd_vs <= 1'b1;
        end else if (pix_tick) begin
            if (x_q == sweep_q) begin
                lcd_r <= 5'd31;
                lcd_g <= 6'd63;
                lcd_b <= 5'd31;
            end else begin
                lcd_r <= nr;
                lcd_g <= ng;
                lcd_b <= nb;
            end
            lcd_de <= (x < H_ACT) && (y < V_ACT);
            lcd_hs <= hsync_n;
            lcd_vs <= vsync_n;
        end
    end

    assign lcd_dclk = (ph < 4'd6);

endmodule
