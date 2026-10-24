//=============================================================================
// ttp229_rx.v  --  2-wire (serial) receiver for a TTP229 16-key module
//
//  Protocol (TTP229 datasheet, 2-wire mode)
//      * SDO idles HIGH.  When a key event is latched the chip emits a
//        DV (data valid) pulse: SDO LOW for ~93 us.
//      * After the DV pulse the master must wait Tw > 10 us, then read
//        16 bits out of SDO by clocking SCL.  Each bit is valid while
//        SCL is LOW; bit 0 (TP0) comes first.
//      * Bit value 0 means the key IS touched (SDO is active low).
//      * If SCL stays HIGH for more than ~2 s the chip enters sleep mode;
//        pulling SCL LOW wakes it again (~0.6 s warm-up).
//
//  Clocks (sys_clk = 108 MHz)
//      WARM_CLK  64_800_000 = 0.600 s   power-on warm-up
//      DV_QUAL       1_080  =  10 us    minimum SDO low width accepted as DV
//      TW_CLK        1_200  = 11.1 us   Tw  (> 10 us)
//      SCL_HALF        108  =  1.00 us  SCL ~ 500 kHz
//      SLEEP_CLK  21_600_000= 0.200 s   no-frame timeout -> wake pulse
//
//  Outputs
//      key_raw[15:0] : 1 = key pressed, bit i = TP<i>
//      frame_ok      : one clk pulse after each good 16-bit read
//      awake         : 1 once the warm-up finished
//=============================================================================
`timescale 1ns / 1ps

module ttp229_rx #(
    parameter integer WARM_CLK   = 64_800_000,
    parameter integer DV_QUAL    = 1_080,
    parameter integer TW_CLK     = 1_200,
    parameter integer SCL_HALF   = 108,
    parameter integer SLEEP_CLK  = 21_600_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tp_sdo,          // from TTP229 SDO
    output reg         tp_scl,          // to   TTP229 SCL
    output reg  [15:0] key_raw,
    output reg         frame_ok,
    output reg         awake
);

    //------------------------------------------------------------------
    // input synchroniser
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

    //------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------
    localparam [3:0] S_WARM   = 4'd0,
                     S_IDLE   = 4'd1,
                     S_DVCHK  = 4'd2,
                     S_DVEND  = 4'd3,
                     S_TW     = 4'd4,
                     S_BITLO  = 4'd5,
                     S_BITHI  = 4'd6,
                     S_DONE   = 4'd7,
                     S_WAKE   = 4'd8;

    reg [3:0]  state;
    reg [26:0] cnt;         // generic delay counter
    reg [3:0]  bitv;        // current bit index 0..15
    reg [15:0] shreg;       // assembled keys (1 = touched)
    reg [26:0] idle_cnt;    // time since the last good frame

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_WARM;
            cnt      <= 27'd0;
            bitv     <= 4'd0;
            shreg    <= 16'd0;
            idle_cnt <= 27'd0;
            tp_scl   <= 1'b1;
            key_raw  <= 16'd0;
            frame_ok <= 1'b0;
            awake    <= 1'b0;
        end else begin
            frame_ok <= 1'b0;

            // idle watchdog -- counts up while no frame is completed
            if (state == S_DONE)
                idle_cnt <= 27'd0;
            else if (idle_cnt != SLEEP_CLK)
                idle_cnt <= idle_cnt + 27'd1;

            case (state)
                //------------------------------------------------------
                S_WARM: begin
                    tp_scl <= 1'b1;
                    if (cnt == WARM_CLK-1) begin
                        cnt     <= 27'd0;
                        awake   <= 1'b1;
                        state   <= S_IDLE;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // wait for SDO to fall and stay low long enough to be a DV
                S_IDLE: begin
                    tp_scl <= 1'b1;
                    cnt    <= 27'd0;
                    if (!sdo_s1)
                        state <= S_DVCHK;
                    else if (idle_cnt >= SLEEP_CLK)
                        state <= S_WAKE;
                end

                S_DVCHK: begin
                    if (sdo_s1) begin
                        // glitch, shorter than DV_QUAL -> not a data valid
                        cnt   <= 27'd0;
                        state <= S_IDLE;
                    end else if (cnt == DV_QUAL-1) begin
                        cnt   <= 27'd0;
                        state <= S_DVEND;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // DV qualified: wait for it to end, then Tw, then clock
                S_DVEND: begin
                    if (sdo_s1) begin
                        cnt   <= 27'd0;
                        state <= S_TW;
                    end
                end

                S_TW: begin
                    tp_scl <= 1'b1;
                    if (cnt == TW_CLK-1) begin
                        cnt   <= 27'd0;
                        bitv  <= 4'd0;
                        state <= S_BITLO;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                // bit is valid while SCL is low -- sample at the end
                S_BITLO: begin
                    tp_scl <= 1'b0;
                    if (cnt == SCL_HALF-1) begin
                        cnt   <= 27'd0;
                        shreg <= {~sdo_s1, shreg[15:1]};   // bit0 first, invert
                        state <= S_BITHI;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                S_BITHI: begin
                    tp_scl <= 1'b1;
                    if (cnt == SCL_HALF-1) begin
                        cnt <= 27'd0;
                        if (bitv == 4'd15) begin
                            bitv  <= 4'd0;
                            state <= S_DONE;
                        end else begin
                            bitv  <= bitv + 4'd1;
                            state <= S_BITLO;
                        end
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                //------------------------------------------------------
                S_DONE: begin
                    tp_scl   <= 1'b1;
                    key_raw  <= shreg;
                    frame_ok <= 1'b1;
                    state    <= S_IDLE;
                end

                //------------------------------------------------------
                // no frame for SLEEP_CLK: pulse SCL low to wake the chip
                S_WAKE: begin
                    tp_scl <= 1'b0;
                    if (cnt == 27'd10800) begin        // 100 us wake pulse
                        cnt   <= 27'd0;
                        state <= S_WARM;
                    end else begin
                        cnt <= cnt + 27'd1;
                    end
                end

                default: state <= S_WARM;
            endcase
        end
    end

endmodule
