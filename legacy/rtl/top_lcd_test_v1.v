//=============================================================================
//  top_lcd_test.v  --  standalone LCD / touch bring-up build
//
//  Purpose:  prove the 4.3" 480x272 40P RGB panel lights up and that the
//  TTP229 16-key pad is read correctly, WITHOUT the audio path.  The I2S
//  pins are simply not present in this top module, and
//  constraints/lcd_test.cst does not constrain them, so they stay
//  unconnected (safe to leave floating on the MAX98357 module input).
//
//  What is on the screen (top to bottom):
//
//      y   0.. 47    grey ramp, 32 bars, 15 px each   (R,G,B together)
//      y  48.. 95    red ramp,   32 bars
//      y  96..143    green ramp, 32 bars               (green is 6 bit)
//      y 144..191    blue ramp,  32 bars
//      y 192..223    16 solid colour blocks, 30 px each
//      y 224..271    16 key boxes, 30 px each, lit while TP_n is touched
//
//  Overlays:
//      * a 16x16 status square in the top-left corner
//            green  = TTP229 link up (frames arriving)
//            red    = never seen a frame yet / asleep
//      * a 1 px white sweep line that moves one column per frame, so a
//        frozen picture is immediately obvious
//
//  If the ramps look right but red and blue are swapped, or the bars step
//  2 levels at a time, the RGB bit mapping in constraints/lcd_test.cst is
//  wrong -- that is exactly what this pattern is for.
//=============================================================================
`timescale 1ns / 1ps

module top_lcd_test #(
    // TTP229 timings, all in clk_sys (=108 MHz) cycles
    parameter integer WARM_CLK  = 64_800_000,   // 0.6 s power-up settle
    parameter integer DV_QUAL   = 1_080,        // 10 us  -> data-valid pulse
    parameter integer TW_CLK    = 1_200,        // 11 us  -> SCL timeout reset
    parameter integer SCL_HALF  = 108,          // 1.04 us -> 480 kHz
    parameter integer SLEEP_CLK = 21_600_000    // 200 ms -> assume asleep
)(
    input  wire       clk27,
    input  wire       rst_n,

    input  wire       tp_sdo,
    output wire       tp_scl,

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
    // touch pad
    //------------------------------------------------------------------
    wire [15:0] key_raw;
    wire        tp_awake;
    wire        tp_active;

    ttp229_rx #(
        .WARM_CLK  (WARM_CLK),
        .DV_QUAL   (DV_QUAL),
        .TW_CLK    (TW_CLK),
        .SCL_HALF  (SCL_HALF),
        .SLEEP_CLK (SLEEP_CLK)
    ) u_ttp (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .tp_sdo   (tp_sdo),
        .tp_scl   (tp_scl),
        .key_raw  (key_raw),
        .awake    (tp_awake),
        .frame_ok (tp_active)
    );

    //------------------------------------------------------------------
    // panel timing
    //------------------------------------------------------------------
    wire [3:0] ph;
    wire       pix_tick;
    wire [9:0] x;
    wire [9:0] y;

    lcd_timing u_tmg (
        .clk     (clk_sys),
        .rst_n   (srst_n),
        .ph      (ph),
        .pix_tick(pix_tick),
        .x       (x),
        .y       (y)
    );

    //------------------------------------------------------------------
    // sweep counter, advances once per frame
    //------------------------------------------------------------------
    reg [9:0] sweep;
    always @(posedge clk_sys) begin
        if (!srst_n)
            sweep <= 10'd0;
        else if (pix_tick && x == 10'd0 && y == 10'd0)
            sweep <= (sweep == 10'd479) ? 10'd0 : sweep + 10'd1;
    end

    //------------------------------------------------------------------
    // pixel pattern -- two registered stages
    //   ph 5 : latch x / y / touch state
    //   ph 8 : colour from the latched values
    //   ph 10: drive the pins together with de / hs / vs
    //------------------------------------------------------------------
    reg [9:0]  x_q, y_q;
    reg [15:0] key_q;
    reg        awake_q, active_q;
    reg [9:0]  sweep_q;

    wire [20:0] bar_m = x * 21'd4369;      // x / 15  -> 0..31   (65536/15)
    wire [20:0] box_m = x * 21'd2185;      // x / 30  -> 0..15   (65536/30)

    reg [4:0]  bar_q;                      // ramp index
    reg [3:0]  box_q;                      // block / key index
    reg        key_on_q;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            x_q <= 10'd0;  y_q <= 10'd0;
            key_q <= 16'd0;
            awake_q <= 1'b0; active_q <= 1'b0;
            sweep_q <= 10'd0;
            bar_q <= 5'd0;  box_q <= 4'd0;  key_on_q <= 1'b0;
        end else begin
            if (ph == 4'd5) begin
                x_q     <= x;
                y_q     <= y;
                key_q   <= key_raw;
                awake_q <= tp_awake;
                active_q<= tp_active;
                sweep_q <= sweep;
                bar_q   <= bar_m[20:16];
                box_q   <= box_m[19:16];
                key_on_q<= key_raw[box_m[20:16]];
            end
        end
    end

    //------------------------------------------------------------------
    // colour lookup
    //------------------------------------------------------------------
    reg [4:0] nr;
    reg [5:0] ng;
    reg [4:0] nb;

    // 16 reference colours for the block row
    function [15:0] blk_col;               // {r[4:0], g[5:0], b[4:0]}
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

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            nr <= 5'd0; ng <= 6'd0; nb <= 5'd0;
        end else if (ph == 4'd8) begin
            // ---- status square, top-left 16x16 ----
            if (x_q < 10'd16 && y_q < 10'd16) begin
                if (active_q) begin
                    nr <= 5'd0;  ng <= 6'd48; nb <= 5'd0;      // link up
                end else if (awake_q) begin
                    nr <= 5'd31; ng <= 6'd31; nb <= 5'd0;      // awake, no frames
                end else begin
                    nr <= 5'd31; ng <= 6'd0;  nb <= 5'd0;      // still warming up
                end
            end
            // ---- ramps ----
            else if (y_q < 10'd48) begin
                nr <= bar_q;  ng <= {bar_q, 1'b0};  nb <= bar_q;
            end
            else if (y_q < 10'd96) begin
                nr <= bar_q;  ng <= 6'd0;           nb <= 5'd0;
            end
            else if (y_q < 10'd144) begin
                nr <= 5'd0;   ng <= {bar_q, 1'b0};  nb <= 5'd0;
            end
            else if (y_q < 10'd192) begin
                nr <= 5'd0;   ng <= 6'd0;           nb <= bar_q;
            end
            // ---- colour blocks ----
            else if (y_q < 10'd224) begin
                nr <= blk[15:11];  ng <= blk[10:5];  nb <= blk[4:0];
            end
            // ---- key boxes ----
            else begin
                if (key_on_q) begin
                    nr <= 5'd21;  ng <= 6'd63;  nb <= 5'd21;   // touched
                end else begin
                    nr <= 5'd5;   ng <= 6'd10;  nb <= 5'd5;    // idle
                end
            end
        end
    end

    //------------------------------------------------------------------
    // output register: sweep line overlays the final image
    //------------------------------------------------------------------
    wire hsync_n = ~((x >= 10'd482) && (x < 10'd523));
    wire vsync_n = ~((y >= 10'd274) && (y < 10'd284));

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
            lcd_de <= (x < 10'd480) && (y < 10'd272);
            lcd_hs <= hsync_n;
            lcd_vs <= vsync_n;
        end
    end

    assign lcd_dclk = (ph < 4'd6);

endmodule
