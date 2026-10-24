//=============================================================================
//  top_lcd_test.v  --  standalone LCD / touch bring-up build  (v2, diagnostic)
//
//  Purpose:   prove the 4.3" 480x272 40P RGB panel lights up AND show exactly
//  what the TTP229 is putting on the wire, so a wiring or protocol problem can
//  be seen instead of guessed.  No audio path here at all.
//
//  Screen layout (top to bottom):
//
//      y   0.. 15   status strip, full width, colour = link state
//                     red    = settle timer still running
//                     yellow = polling frames, but no key has ever been seen
//                     green  = at least one key is currently down
//      y  16.. 47   grey ramp (32 bars) -- LCD sanity, R=G=B
//      y  48..111   ROW A: 8 key cells, bit sampled while SCL was LOW
//      y 112..175   ROW B: 8 key cells, bit sampled while SCL was HIGH
//      y 176..207   16 reference colour blocks
//      y 208..271   HEX READOUT of the 8-key word: four 7-segment digits of
//                   80x62 px showing 0 0 key[7:4] key[3:0] left to right.
//                   Amber segments on a near-black background.  Read it
//                   straight off a photo -- no bit-cell counting needed.
//                   A green blinker in the right margin proves polling is
//                   alive (it toggles with poll_cnt[5]).
//
//  This module's TTP229 runs in 8-KEY mode (TP2/KYSEL not pulled to VSS), so
//  the chip only transmits D0..D7 and repeats that 8-bit frame.  Every row of
//  bits is therefore 8 cells of 60 px, cell i = TP<i>, i = 0..7.
//  Bright green cell = bit 1, dark cell = bit 0.
//
//  Overlays: a 1 px white sweep line that moves one column per frame, so a
//  frozen picture is immediately obvious.
//=============================================================================
`timescale 1ns / 1ps

module top_lcd_test #(
    // TTP229 timings, all in clk_sys (=108 MHz) cycles
    parameter integer INIT_CLK = 21_600_000,   // 200 ms power-up settle
    parameter integer POLL_CLK = 108_000,      //   1 ms per 16-bit frame
                                               //   (datasheet Tout = 2 ms: no SCL
                                               //    edge for >2 ms resets the serial
                                               //    interface, so keep well inside)
    parameter integer SCL_HALF = 108,          //   1 us  -> 500 kHz
    parameter integer ACTIVE_LOW = 1
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
    wire [15:0] key_lo;
    wire [15:0] key_hi;
    wire [15:0] pcount;
    wire        tp_awake;
    wire        tp_frame;

    ttp229_rx #(
        .INIT_CLK  (INIT_CLK),
        .POLL_CLK  (POLL_CLK),
        .SCL_HALF  (SCL_HALF),
        .ACTIVE_LOW(ACTIVE_LOW)
    ) u_ttp (
        .clk      (clk_sys),
        .rst_n    (srst_n),
        .tp_sdo   (tp_sdo),
        .tp_scl   (tp_scl),
        .key_raw  (key_lo),
        .key_hi   (key_hi),
        .poll_cnt (pcount),
        .frame_ok (tp_frame),
        .awake    (tp_awake)
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
    reg [15:0] key_lo_q, key_hi_q, pcount_q;
    reg        awake_q;
    reg [9:0]  sweep_q;

    wire [20:0] bar_m = x * 21'd4369;      // x / 15  -> 0..31   (65536/15)
    wire [20:0] col_m = x * 21'd2185;      // x / 30  -> 0..15   (65536/30)
    wire [20:0] cel_m = x * 21'd1093;      // x / 60  -> 0..7    (65536/60)

    reg [4:0] bar_q;                       // ramp index
    reg [3:0] col_q;                       // colour block index 0..15
    reg [2:0] cel_q;                       // key cell index 0..7

    //------------------------------------------------------------------
    // hex readout of the 8-key word: 4 digits of 80 x 62 px,
    // origins 20/110/200/290.  Only two digits are needed for 8 keys, so
    // the two left digits are hard zeros and the value reads like 00xx.
    //------------------------------------------------------------------
    reg [6:0] hoff;                        // x inside the digit, 0..89
    reg [3:0] hval;                        // digit value

    always @(*) begin
        if      (x >= 10'd20  && x < 10'd110) begin hoff = x - 10'd20;  hval = 4'h0;           end
        else if (x >= 10'd110 && x < 10'd200) begin hoff = x - 10'd110; hval = 4'h0;           end
        else if (x >= 10'd200 && x < 10'd290) begin hoff = x - 10'd200; hval = key_lo[7:4];    end
        else if (x >= 10'd290 && x < 10'd380) begin hoff = x - 10'd290; hval = key_lo[3:0];    end
        else begin hoff = 7'd0; hval = 4'd0; end
    end

    reg [6:0] hoff_q;
    reg [3:0] hval_q;
    reg       hin_q;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            x_q <= 10'd0;  y_q <= 10'd0;
            key_lo_q <= 16'd0; key_hi_q <= 16'd0; pcount_q <= 16'd0;
            awake_q <= 1'b0;
            sweep_q <= 10'd0;
            bar_q <= 5'd0;  col_q <= 4'd0;  cel_q <= 3'd0;
            hoff_q <= 7'd0; hval_q <= 4'd0; hin_q <= 1'b0;
        end else if (ph == 4'd5) begin
            x_q      <= x;
            y_q      <= y;
            key_lo_q <= key_lo;
            key_hi_q <= key_hi;
            pcount_q <= pcount;
            awake_q  <= tp_awake;
            sweep_q  <= sweep;
            bar_q    <= bar_m[20:16];
            col_q    <= col_m[19:16];
            cel_q    <= cel_m[18:16];
            hoff_q   <= hoff;
            hval_q   <= hval;
            hin_q    <= (x >= 10'd20 && x < 10'd380 && hoff < 7'd80);
        end
    end

    //------------------------------------------------------------------
    // 7-segment decode,  seg = {g,f,e,d,c,b,a}
    //------------------------------------------------------------------
    function [6:0] seg7;
        input [3:0] d;
        begin
            case (d)
                4'h0: seg7 = 7'b0111111;
                4'h1: seg7 = 7'b0000110;
                4'h2: seg7 = 7'b1011011;
                4'h3: seg7 = 7'b1001111;
                4'h4: seg7 = 7'b1100110;
                4'h5: seg7 = 7'b1101101;
                4'h6: seg7 = 7'b1111101;
                4'h7: seg7 = 7'b0000111;
                4'h8: seg7 = 7'b1111111;
                4'h9: seg7 = 7'b1101111;
                4'hA: seg7 = 7'b1110111;
                4'hB: seg7 = 7'b1111100;
                4'hC: seg7 = 7'b0111001;
                4'hD: seg7 = 7'b1011110;
                4'hE: seg7 = 7'b1111001;
                default: seg7 = 7'b1110001;
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // bit-row helpers: the pad is a TTP229 in 8-key mode, so only D0..D7
    // exist.  Eight cells of 60 px, cell i = TP<i>.
    //------------------------------------------------------------------
    wire [7:0] kw_lo = key_lo_q[7:0];
    wire [7:0] kw_hi = key_hi_q[7:0];

    reg lo_bit, hi_bit;
    always @(*) begin
        case (cel_q)
            3'd0: begin lo_bit = kw_lo[0]; hi_bit = kw_hi[0]; end
            3'd1: begin lo_bit = kw_lo[1]; hi_bit = kw_hi[1]; end
            3'd2: begin lo_bit = kw_lo[2]; hi_bit = kw_hi[2]; end
            3'd3: begin lo_bit = kw_lo[3]; hi_bit = kw_hi[3]; end
            3'd4: begin lo_bit = kw_lo[4]; hi_bit = kw_hi[4]; end
            3'd5: begin lo_bit = kw_lo[5]; hi_bit = kw_hi[5]; end
            3'd6: begin lo_bit = kw_lo[6]; hi_bit = kw_hi[6]; end
            default: begin lo_bit = kw_lo[7]; hi_bit = kw_hi[7]; end
        endcase
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

    wire [15:0] blk = blk_col(col_q);

    //------------------------------------------------------------------
    // 7-segment geometry, digit box 80 x 62 px
    //------------------------------------------------------------------
    wire [6:0] hx7  = hoff_q;
    wire [9:0] hy10 = y_q - 10'd208;
    wire [6:0] sg   = seg7(hval_q);

    wire seg_a = sg[0] && hx7>=7'd12 && hx7<7'd68 && hy10<10'd6;
    wire seg_f = sg[5] && hx7>=7'd4  && hx7<7'd11 && hy10>=10'd3  && hy10<10'd30;
    wire seg_b = sg[1] && hx7>=7'd69 && hx7<7'd76 && hy10>=10'd3  && hy10<10'd30;
    wire seg_g = sg[6] && hx7>=7'd12 && hx7<7'd68 && hy10>=10'd28 && hy10<10'd34;
    wire seg_e = sg[4] && hx7>=7'd4  && hx7<7'd11 && hy10>=10'd32 && hy10<10'd59;
    wire seg_c = sg[2] && hx7>=7'd69 && hx7<7'd76 && hy10>=10'd32 && hy10<10'd59;
    wire seg_d = sg[3] && hx7>=7'd12 && hx7<7'd68 && hy10>=10'd56 && hy10<10'd62;
    wire seg_hit = seg_a | seg_f | seg_b | seg_g | seg_e | seg_c | seg_d;

    always @(posedge clk_sys) begin
        if (!srst_n) begin
            nr <= 5'd0; ng <= 6'd0; nb <= 5'd0;
        end else if (ph == 4'd8) begin
            // ---- status strip, full width, 16 px tall ----
            if (y_q < 10'd16) begin
                if (!awake_q) begin
                    nr <= 5'd31; ng <= 6'd0;  nb <= 5'd0;      // settle
                end else if (key_lo_q != 16'd0 || key_hi_q != 16'd0) begin
                    nr <= 5'd0;  ng <= 6'd56; nb <= 5'd0;      // key seen
                end else begin
                    nr <= 5'd31; ng <= 6'd40; nb <= 5'd0;      // polling only
                end
            end
            // ---- grey ramp ----
            else if (y_q < 10'd48) begin
                nr <= bar_q;  ng <= {bar_q, 1'b0};  nb <= bar_q;
            end
            // ---- ROW A : low-phase sample ----
            else if (y_q < 10'd112) begin
                if (lo_bit) begin nr <= 5'd2;  ng <= 6'd60; nb <= 5'd2;  end
                else        begin nr <= 5'd1;  ng <= 6'd5;  nb <= 5'd1;  end
            end
            // ---- ROW B : high-phase sample ----
            else if (y_q < 10'd176) begin
                if (hi_bit) begin nr <= 6'd0 + 5'd28; ng <= 6'd44; nb <= 5'd2; end
                else        begin nr <= 5'd2;  ng <= 6'd4;  nb <= 5'd1;  end
            end
            // ---- reference colour blocks ----
            else if (y_q < 10'd208) begin
                nr <= blk[15:11];  ng <= blk[10:5];  nb <= blk[4:0];
            end
            // ---- hex readout of the latched key word ----
            else begin
                if (hin_q && seg_hit) begin
                    nr <= 5'd31; ng <= 6'd46; nb <= 5'd0;      // lit segment
                end else if (hin_q) begin
                    nr <= 5'd2;  ng <= 6'd5;  nb <= 5'd2;      // digit background
                end else if (x_q >= 10'd400 && x_q < 10'd470) begin
                    if (pcount_q[5]) begin nr <= 5'd0; ng <= 6'd48; nb <= 5'd0; end
                    else             begin nr <= 5'd2; ng <= 6'd6;  nb <= 5'd2; end
                end else begin
                    nr <= 5'd1;  ng <= 6'd3;  nb <= 5'd1;
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
