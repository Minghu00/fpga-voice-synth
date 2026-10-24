//=============================================================================
// ttp229_rx.v  --  TTP229 16-key pad receiver, POLLING version
//
//  Why polling instead of the DV (data-valid) handshake
//  ----------------------------------------------------
//  TTP229 datasheet 3-4 says the 2-wire serial mode "supports always polling
//  data for other device on the system", and the DV handshake is only the
//  alternative.  The DV variant was tried first and behaved badly on real
//  hardware (one key latched, then the link wedged), because the receiver
//  could block forever waiting for SDO to return high.  Polling has no such
//  blocking path: every POLL_CLK cycles a complete 16-bit frame is shifted
//  out of the chip no matter what SDO did before, so the link can never
//  dead-lock and a fresh sample is always only ~2 ms away.
//
//  Protocol (2-wire serial, 16 keys, default ACTIVE LOW)
//  ----------------------------------------------------
//      SCL is a plain clock INPUT to the TTP229; the master drives it.
//      SDO is the chip's data OUTPUT.
//      Bit 0 (D0 = TP0) comes out first.
//      Data is captured twice per bit -- once while SCL is low and once
//      while SCL is high -- so the caller can find out experimentally which
//      edge this particular module actually presents its data on.  Nothing
//      is decided here; both words are handed out:
//           key_lo[15:0] : bit sampled at the end of the SCL LOW  phase
//           key_hi[15:0] : bit sampled at the end of the SCL HIGH phase
//      key_raw = key_lo, with the ACTIVE_LOW inversion already applied
//      (1 = touched), because that is the conventional timing.
//
//      If SCL sees no edge for ~2 ms the chip resets its serial interface to
//      stand-by; that is harmless here because every poll re-sends a full
//      16-clock burst from scratch.
//
//  Clocks (clk = 108 MHz)
//      INIT_CLK  21_600_000 = 200 ms  power-on settle (>125 ms wake-up)
//      POLL_CLK     108_000 =   1 ms  one full 16-bit frame every 1 ms
//                            (must stay well under the 2 ms SCL timeout)
//      SCL_HALF         108 =   1 us  SCL ~ 500 kHz (datasheet: 1k..512k)
//
//  Outputs
//      key_raw[15:0]  1 = touched, bit i = TP<i>   (from the low-phase word)
//      key_hi [15:0]  1 = touched, bit i = TP<i>   (from the high-phase word)
//      poll_cnt[15:0]  free-running frame counter -- proves polling is alive
//      frame_ok       one clk pulse after each complete frame
//      awake          1 once the power-on settle has elapsed
//=============================================================================
`timescale 1ns / 1ps

module ttp229_rx #(
    parameter integer INIT_CLK   = 21_600_000,
    parameter integer POLL_CLK   = 108_000,
    parameter integer SCL_HALF   = 108,
    parameter integer ACTIVE_LOW = 1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tp_sdo,          // from TTP229 SDO
    output reg         tp_scl,          // to   TTP229 SCL
    output reg  [15:0] key_raw,
    output reg  [15:0] key_hi,
    output reg  [15:0] poll_cnt,
    output reg         frame_ok,
    output reg         awake
);

    //------------------------------------------------------------------
    // input synchroniser (2 FF)
    //------------------------------------------------------------------
    reg sdo_s0, sdo_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdo_s0 <= 1'b1;
            sdo_s1 <= 1'b1;
        end else begin
            sdo_s0 <= tp_sdo;
            sdo_s1 <= sdo_s0;
        end
    end

    // active-low by default: a touched key pulls SDO low
    wire bit_now = ACTIVE_LOW ? ~sdo_s1 : sdo_s1;

    //------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------
    localparam [2:0] S_INIT = 3'd0,
                     S_WAIT = 3'd1,
                     S_LO   = 3'd2,
                     S_HI   = 3'd3,
                     S_LATCH= 3'd4;

    reg [2:0]  state;
    reg [26:0] cnt;
    reg [4:0]  bitv;
    reg [15:0] cand;        // candidate word, must repeat before it is taken
    reg [1:0]  stab_cnt;    // how many consecutive polls produced cand
    reg [15:0] sh_lo;
    reg [15:0] sh_hi_tmp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_INIT;
            cnt      <= 27'd0;
            bitv     <= 5'd0;
            sh_lo    <= 16'd0;
        cand     <= 16'd0;
        stab_cnt <= 2'd0;
            sh_hi_tmp<= 16'd0;
            tp_scl   <= 1'b1;
            key_raw  <= 16'd0;
            key_hi   <= 16'd0;
            poll_cnt <= 16'd0;
            frame_ok <= 1'b0;
            awake    <= 1'b0;
        end else begin
            frame_ok <= 1'b0;

            case (state)
                //------------------------------------------------------
                S_INIT: begin
                    tp_scl <= 1'b1;
                    if (cnt == INIT_CLK-1) begin
                        cnt   <= 27'd0;
                        awake <= 1'b1;
                        state <= S_WAIT;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // gap between frames -- SCL parks high
                S_WAIT: begin
                    tp_scl <= 1'b1;
                    if (cnt == POLL_CLK-1) begin
                        cnt   <= 27'd0;
                        bitv  <= 5'd0;
                        state <= S_LO;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // SCL low half: the low-phase sample is taken at its end
                S_LO: begin
                    tp_scl <= 1'b0;
                    if (cnt == SCL_HALF-1) begin
                        cnt   <= 27'd0;
                        sh_lo <= {bit_now, sh_lo[15:1]};
                        state <= S_HI;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // SCL high half: the high-phase sample is taken at its end
                S_HI: begin
                    tp_scl <= 1'b1;
                    if (cnt == SCL_HALF-1) begin
                        cnt   <= 27'd0;
                        sh_hi_tmp <= {bit_now, sh_hi_tmp[15:1]};
                        if (bitv == 5'd15) begin
                            bitv  <= 5'd0;
                            state <= S_LATCH;
                        end else begin
                            bitv  <= bitv + 5'd1;
                            state <= S_LO;
                        end
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // Accept a new key word only after the SAME value has come
                // back STABLE_N polls in a row.
                //
                // Why: the TTP229 re-scans and refreshes its output register
                // every T_resp (32 ms).  If a poll straddles that refresh, or
                // if the pad is just very sensitive, the chip can hand out one
                // wrong word for a single poll.  At 1 ms polling a real key
                // press is perfectly steady, but such a glitch word would set
                // a spurious bit for 1 ms -- which on this instrument starts a
                // note (audible click) and flashes a key cell.  Three
                // consecutive identical polls cost 3 ms of latency and reject
                // any glitch shorter than that.
                S_LATCH: begin
                    tp_scl   <= 1'b1;
                    key_hi   <= sh_hi_tmp;
                    poll_cnt <= poll_cnt + 16'd1;
                    frame_ok <= 1'b1;
                    state    <= S_WAIT;

                    if (sh_lo == cand) begin
                        if (stab_cnt != 2'd3)
                            stab_cnt <= stab_cnt + 2'd1;
                        if (stab_cnt == 2'd2)
                            key_raw <= cand;      // third identical poll
                    end else begin
                        cand     <= sh_lo;
                        stab_cnt <= 2'd1;
                    end
                end

                default: state <= S_INIT;
            endcase
        end
    end

endmodule
