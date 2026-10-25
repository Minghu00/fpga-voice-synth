//============================================================================
//  liss_render.v -- Lissajous (X-Y) pre-renderer for the display
//
//  A raster row-scan cannot plot an X-Y figure directly: the column is given
//  by the sweep, but a Lissajous needs the column to be given by the LEFT
//  sample.  This module solves it by pre-rendering the figure once per frame
//  into a per-column vertical span table:
//
//      for every sample i in 0..511
//          xb = clamp(240 + (L[i] >>> 6), 0, 479)
//          y  = clamp( 68 + (R[i] >>> 6), 0, 135)
//          ymin[xb] = min(ymin[xb], y)
//          ymax[xb] = max(ymax[xb], y)
//
//  The display then only has to draw a vertical segment from ymin[x] to
//  ymax[x] for each column x -- exactly the same segment-drawing trick the
//  waveform and envelope pages already use.
//
//  WHY A SPAN TABLE (and not a 1-bit frame cache):
//      a 480x136 bit cache is 65280 bits but needs random single-bit writes,
//      i.e. read-modify-write on a byte-wide array for every point.  The span
//      table is 512 x 16 bit = 1 BSRAM and its read-modify-write is already
//      16 bit wide, so one point costs one read + one write.  The only price
//      is that overlapping branches of the figure are filled in rather than
//      drawn as separate strokes -- which is what a real analogue X-Y scope
//      looks like anyway.
//
//  WHEN IT RUNS:
//      entirely inside vertical blanking.  Cost is 512 clear cycles +
//      512 x 6 accumulate cycles = 3584 clocks, against 14 lines x 525 px x
//      12 clk = 88200 clocks of blanking.  Because the update happens in
//      vblank, a single RAM is enough: the image it destroys is the one that
//      was just displayed, and the new one is ready before the next active
//      area starts.
//
//  EMPTY MARKER: a column that received no samples is stored as
//      {ymax = 0, ymin = 255};  the display treats ymin > ymax as "nothing".
//
//  Scaling note: the >>> 6 map (1 count = 1/64 pixel) makes a full-scale
//  mixer output span +-512 pixels, so an 8-voice chord of a few thousand
//  counts lands well inside the 136-row box; the clamp keeps a saturated
//  peak from wrapping.
//
//  SEQUENCER (one sample per 6 clocks):
//      M_H0  hist_addr <= i
//      M_H1  hl_q <= hist_l, hr_q <= hist_r        (hist latency = 1 clk)
//      M_H2  yv_q <= f(hr_q); raddr <= f(hl_q)     (BSRAM read request)
//      M_H3  waddr <= raddr                        (read in flight)
//      M_H4  rd_q holds mem[xb] -> merge + RAM write
//      M_H5  cnt++
//============================================================================
`timescale 1ns / 1ps

module liss_render (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vblank,        // high during vertical blanking
    // history read port (own dedicated stereo wave_buf)
    output reg  [8:0]  hist_addr,
    input  wire [15:0] hist_l,
    input  wire [15:0] hist_r,
    // display read port
    input  wire [8:0]  disp_addr,
    output wire [15:0] disp_span      // {ymax[7:0], ymin[7:0]}
);

    localparam [2:0] M_IDLE = 3'd0,
                     M_CLR  = 3'd1,
                     M_H0   = 3'd2,
                     M_H1   = 3'd3,
                     M_H2   = 3'd4,
                     M_H3   = 3'd5,
                     M_H4   = 3'd6,
                     M_H5   = 3'd7;

    localparam [15:0] SPAN_EMPTY = {8'd0, 8'd255};

    reg [15:0] mem [0:511];

    reg [2:0] st;
    reg [8:0] cnt;

    reg [8:0] waddr;
    reg [8:0] raddr;

    reg  vb_q;
    wire vb_rise = vblank && !vb_q;

    // ---- history latch / coordinate compute --------------------------------
    reg signed [15:0] hl_q, hr_q;
    reg        [7:0]  yv_q;

    wire signed [15:0] sl6 = hl_q >>> 6;
    wire signed [15:0] sr6 = hr_q >>> 6;
    wire signed [16:0] xt  = 17'sd240 + {{1{sl6[15]}}, sl6};
    wire signed [16:0] yt  = 17'sd 68 + {{1{sr6[15]}}, sr6};
    wire        [8:0]  xb  = (xt < 17'sd0)   ? 9'd0   :
                             (xt > 17'sd479) ? 9'd479 : xt[8:0];
    wire        [7:0]  yv  = (yt < 17'sd0)   ? 8'd0   :
                             (yt > 17'sd135) ? 8'd135 : yt[7:0];

    // ---- RAM ---------------------------------------------------------------
    wire        acc_run = (st != M_IDLE);
    wire [8:0]  rd_addr = acc_run ? raddr : disp_addr;
    reg  [15:0] rd_q;

    wire        we_clr = (st == M_CLR);
    wire        we_mrg = (st == M_H4);
    wire [8:0]  wr_addr = we_clr ? cnt : waddr;

    wire        emp_o  = (rd_q[7:0] > rd_q[15:8]);          // ymin > ymax
    wire [7:0]  ymin_n = (emp_o || (yv_q < rd_q[7:0]))  ? yv_q : rd_q[7:0];
    wire [7:0]  ymax_n = (emp_o || (yv_q > rd_q[15:8])) ? yv_q : rd_q[15:8];
    wire [15:0] wr_data = we_clr ? SPAN_EMPTY : {ymax_n, ymin_n};

    always @(posedge clk) begin
        if (we_clr || we_mrg)
            mem[wr_addr] <= wr_data;
        rd_q <= mem[rd_addr];
    end

    assign disp_span = rd_q;

    // ---- sequencer ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= M_IDLE;
            cnt       <= 9'd0;
            waddr     <= 9'd0;
            raddr     <= 9'd0;
            hist_addr <= 9'd0;
            hl_q      <= 16'sd0;
            hr_q      <= 16'sd0;
            yv_q      <= 8'd0;
            vb_q      <= 1'b0;
        end else begin
            vb_q <= vblank;
            case (st)
                M_IDLE: begin
                    cnt <= 9'd0;
                    if (vb_rise) st <= M_CLR;
                end

                M_CLR: begin
                    if (cnt == 9'd511) begin
                        cnt <= 9'd0;
                        st  <= M_H0;
                    end else begin
                        cnt <= cnt + 9'd1;
                    end
                end

                M_H0: begin
                    hist_addr <= cnt;
                    st        <= M_H1;
                end

                M_H1: begin
                    hl_q <= hist_l;
                    hr_q <= hist_r;
                    st   <= M_H2;
                end

                M_H2: begin
                    raddr <= xb;
                    yv_q  <= yv;
                    st    <= M_H3;
                end

                M_H3: begin
                    waddr <= raddr;
                    st    <= M_H4;
                end

                M_H4: st <= M_H5;                 // merge + write happen here

                M_H5: begin
                    if (cnt == 9'd511) begin
                        cnt <= 9'd0;
                        st  <= M_IDLE;
                    end else begin
                        cnt <= cnt + 9'd1;
                        st  <= M_H0;
                    end
                end

                default: st <= M_IDLE;
            endcase
        end
    end

endmodule
