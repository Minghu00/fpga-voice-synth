//============================================================================
//  lcd_panel.v -- 480x272 RGB565 performance display
//
//  Layout (matches 显示方案_RGB.md):
//
//      y   0..119   x   0..479   waveform scope, 480 samples of history
//      y 120..255   x   0..135   X-Y phase portrait ("Lissajous")
//      y 120..255   x 136..471   16 per-voice envelope bars (21 px each)
//      y 256..271   x   0..479   16 touch-key indicators (30 px each)
//
//  No frame buffer and no line-drawing hardware: every pixel is decided
//  from its own (x,y) plus two samples read from the 512-entry history RAM.
//
//  Everything is spaced out over the 12-clock pixel period, because doing
//  the decode in one cycle cost a 12-level path and dropped Fmax to
//  61.6 MHz.  The pipeline is
//
//      ph  0 : waveform/portrait address A0 out
//      ph  2 : capture d0 = mem[A0], address A1 out
//      ph  4 : capture d1 = mem[A1]
//      ph  5 : register the three multiplies and the two sample registers
//      ph  7 : register derived geometry (screen y, portrait point, bar
//              index, envelope level, key level)
//      ph  8 : register the four hit flags
//      ph  9 : pixel colour -> lcd_r/g/b
//      ph 10 : final register stage together with de / hs / vs (pix_tick)
//
//  x_q/y_q are latched at ph 5 and still describe the pixel being emitted,
//  so the colour and the sync signals can never drift apart.
//============================================================================
`timescale 1ns / 1ps

module lcd_panel #(
    parameter integer H_ACT  = 480,
    parameter integer V_ACT  = 272
)(
    input  wire         clk,
    input  wire         rst_n,

    // audio history write side (one write per audio frame)
    input  wire         wr_en,
    input  wire [8:0]   wr_addr,
    input  wire [15:0]  wr_data,

    // live state for the bar / key regions
    input  wire [255:0] env_flat,
    input  wire [15:0]  key_raw,

    // panel
    output wire         lcd_dclk,
    output reg          lcd_hs,
    output reg          lcd_vs,
    output reg          lcd_de,
    output reg  [4:0]   lcd_r,
    output reg  [5:0]   lcd_g,
    output reg  [4:0]   lcd_b
);
    //------------------------------------------------------------------
    // timing
    //------------------------------------------------------------------
    wire [3:0] ph;
    wire       pix_tick;
    wire [9:0] x;
    wire [9:0] y;

    lcd_timing #(.H_ACT(H_ACT), .V_ACT(V_ACT)) u_tmg (
        .clk       (clk),
        .rst_n     (rst_n),
        .ph        (ph),
        .pix_tick  (pix_tick),
        .x         (x),
        .y         (y)
    );

    //------------------------------------------------------------------
    // history RAM, one snapshot per line
    //------------------------------------------------------------------
    reg  [8:0]  base;                  // oldest sample shown on this line
    reg  [8:0]  ra;
    wire [15:0] rd_data;
    reg  [15:0] d0;                    // sample at this column
    reg  [15:0] d1;                    // previous sample

    wire       in_wave = (y < 10'd120);

    // column -> sample index
    wire [8:0] x9   = x[8:0];
    wire [9:0] idx_w = {1'b0, base} + {1'b0, x9};                            // base + x
    wire [9:0] idx_l = {1'b0, base} + {1'b0, x9} + {1'b0, x9} + {1'b0, x9};  // base + 3x

    wire [9:0] idx_cur = in_wave ? idx_w : idx_l;
    wire [9:0] a0 = idx_cur[8:0];
    wire [9:0] a1 = idx_cur - 10'd1;

    wave_buf u_buf (
        .clk     (clk),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_addr (ra),
        .rd_data (rd_data)
    );

    //------------------------------------------------------------------
    // pipeline stage 1 (ph 5): multiplies and sample registers
    //------------------------------------------------------------------
    reg signed [31:0] m_cur, m_prev;
    reg        [20:0] m_bx;
    reg        [19:0] m_k;
    reg signed [15:0] s_cur_q, dx_q;
    reg        [9:0]  x_q, y_q;

    wire signed [15:0] s_cur  = d0;
    wire signed [15:0] s_prev = d1;
    wire [9:0]  bx = x - 10'd136;

    //------------------------------------------------------------------
    // pipeline stage 2 (ph 7): geometry
    //------------------------------------------------------------------
    reg signed [15:0] pyc_q, pyp_q;    // waveform screen rows
    reg signed [15:0] ppx_q, ppy_q;    // portrait point
    reg        [3:0]  lvl_q;           // envelope level of the hovered bar
    reg               key_q;

    // NOTE: both muxes must be driven from the ph-5 registers, not from the
    // ph-7 outputs of this same stage, or they would select last pixel's bar.
    wire [15:0] env_sel = env_flat[m_bx[19:16]*16 +: 16];

    //------------------------------------------------------------------
    // pipeline stage 3 (ph 8): hit flags
    //------------------------------------------------------------------
    reg               w_hit, l_hit, b_hit;
    reg               key_on;
    reg        [3:0]  lvl_r;
    reg               wave_reg, mid_reg;

    wire signed [15:0] ylo = (pyc_q < pyp_q) ? pyc_q : pyp_q;
    wire signed [15:0] yhi = (pyc_q < pyp_q) ? pyp_q : pyc_q;
    wire        [15:0] yq16 = {6'b0, y_q};
    wire signed [15:0] dxp = x_q - ppx_q;
    wire signed [15:0] dyp = y_q - ppy_q;
    wire [9:0] bartop = 10'd256 - {6'b0, lvl_q, 3'b0};

    //------------------------------------------------------------------
    // pipeline stages 1..3
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            base  <= 9'd0;
            ra    <= 9'd0;
            d0    <= 16'd0;
            d1    <= 16'd0;
            m_cur <= 32'sd0;
            m_prev<= 32'sd0;
            m_bx  <= 21'd0;
            m_k   <= 20'd0;
            s_cur_q <= 16'sd0;
            dx_q    <= 16'sd0;
            x_q <= 10'd0;
            y_q <= 10'd0;
            pyc_q <= 16'sd0;  pyp_q <= 16'sd0;
            ppx_q <= 16'sd0;  ppy_q <= 16'sd0;
            lvl_q <= 4'd0;    key_q <= 1'b0;
            w_hit <= 1'b0; l_hit <= 1'b0; b_hit <= 1'b0;
            key_on <= 1'b0; lvl_r <= 4'd0;
            wave_reg <= 1'b0; mid_reg <= 1'b0;
        end else begin
            // ---- sample fetch ----
            if (ph == 4'd0) begin
                ra <= a0[8:0];
                if (x == 10'd0 && y < V_ACT)
                    base <= wr_addr - 9'd480;      // 480 samples = 9.96 ms
            end else if (ph == 4'd2) begin
                d0 <= rd_data;
                ra <= a1[8:0];
            end else if (ph == 4'd4) begin
                d1 <= rd_data;
            end

            // ---- stage 1 ----
            if (ph == 4'd5) begin
                m_cur   <= s_cur * 32'sd120;
                m_prev  <= s_prev * 32'sd120;
                m_bx    <= {11'b0, bx} * 21'd3121;      // /21 by reciprocal
                m_k     <= {10'b0, x}  * 20'd2185;      // /30 by reciprocal
                s_cur_q <= s_cur;
                dx_q    <= s_cur - s_prev;
                x_q     <= x;
                y_q     <= y;
            end

            // ---- stage 2 ----
            if (ph == 4'd7) begin
                pyc_q <= 16'sd60  - (m_cur  >>> 16);
                pyp_q <= 16'sd60  - (m_prev >>> 16);
                ppx_q <= 16'sd68  + (s_cur_q >>> 9);
                ppy_q <= 16'sd188 + (dx_q    >>> 4);
                lvl_q <= env_sel[15:12];
                key_q <= key_raw[m_k[19:16]];
            end

            // ---- stage 3 ----
            if (ph == 4'd8) begin
                wave_reg <= (y_q < 10'd120);
                mid_reg  <= (y_q >= 10'd120) && (y_q < 10'd256);
                // a zero-extended y_q compared against a negative signed py
                // turns into a huge unsigned value, so off-screen traces are
                // rejected without a separate guard
                w_hit    <= (y_q <= 10'd119) &&
                            (yq16 >= ylo) && (yq16 <= yhi);
                l_hit    <= (dxp >= -16'sd1) && (dxp <= 16'sd1) &&
                            (dyp >= -16'sd1) && (dyp <= 16'sd1);
                b_hit    <= (x_q >= 10'd136) && (x_q < 10'd472) &&
                            (y_q >= bartop);
                key_on   <= key_q;
                lvl_r    <= lvl_q;
            end
        end
    end

    //------------------------------------------------------------------
    // stage 4 (ph 9): colour
    //------------------------------------------------------------------
    reg [4:0] nr;
    reg [5:0] ng;
    reg [4:0] nb;

    always @(posedge clk) begin
        if (!rst_n) begin
            nr <= 5'd2;  ng <= 6'd6;  nb <= 5'd12;
        end else if (ph == 4'd9) begin
            nr <= 5'd2;  ng <= 6'd6;  nb <= 5'd12;          // background
            if (wave_reg) begin
                if (w_hit) begin
                    nr <= 5'd6;  ng <= 6'd52;  nb <= 5'd10; // trace: green
                end
            end else if (mid_reg) begin
                if (x_q < 10'd136) begin
                    if (l_hit) begin
                        nr <= 5'd31;  ng <= 6'd44;  nb <= 5'd2;   // portrait: amber
                    end
                end else if (b_hit) begin
                    nr <= 5'd26;
                    ng <= 6'd30 - {2'b0, lvl_r, 1'b0};
                    nb <= 5'd6;
                end
            end else begin
                if (key_on) begin
                    nr <= 5'd31;  ng <= 6'd26;  nb <= 5'd0;       // key down: orange
                end else begin
                    nr <= 5'd5;   ng <= 6'd8;    nb <= 5'd16;     // idle: dim blue
                end
            end
        end
    end

    //------------------------------------------------------------------
    // output register -- de / hs / vs share the colour's final stage
    //------------------------------------------------------------------
    wire hsync_n = ~((x >= H_ACT + 2) && (x < H_ACT + 43));
    wire vsync_n = ~((y >= V_ACT + 2) && (y < V_ACT + 12));

    always @(posedge clk) begin
        if (!rst_n) begin
            lcd_r  <= 5'd0;
            lcd_g  <= 6'd0;
            lcd_b  <= 5'd0;
            lcd_de <= 1'b0;
            lcd_hs <= 1'b1;
            lcd_vs <= 1'b1;
        end else if (pix_tick) begin
            lcd_r  <= nr;
            lcd_g  <= ng;
            lcd_b  <= nb;
            lcd_de <= (x < H_ACT) && (y < V_ACT);
            lcd_hs <= hsync_n;
            lcd_vs <= vsync_n;
        end
    end

    // 9 MHz pixel clock, high for the first half of the pixel period
    assign lcd_dclk = (ph < 4'd6);

endmodule
