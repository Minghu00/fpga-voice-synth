//=============================================================================
// ttp229_model.v  --  behavioural TTP229 16-key pad, 2-wire serial (polling)
//
//  Matches the polling receiver: the master bursts 16 SCL clocks whenever it
//  likes, and the chip simply shifts out TP0..TP15, bit 0 first, presenting
//  each bit for the whole SCL-low phase.
//
//      idle high for IDLE_CLK  -> frame restarts, bit 0 is presented
//      every SCL falling edge -> advance one bit
//
//  ACTIVE_LOW = 1 models the TTP229 default: a touched pad reads as 0 on SDO.
//
//  GLITCH TESTING
//      glitch / gkeys let a testbench make exactly ONE burst carry a bogus
//      word (this models the real chip handing out a wrong word for a single
//      scan while it refreshes its internal registers).  Raise `glitch` for a
//      while; the next complete burst sends `gkeys` instead of `keys`, and the
//      request is then cleared so the following bursts are clean again.
//=============================================================================
`timescale 1ns / 1ps

module ttp229_model #(
    parameter integer IDLE_CLK   = 40,
    parameter integer ACTIVE_LOW = 1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scl,
    input  wire [15:0] keys,      // 1 = this pad is being touched
    input  wire [15:0] gkeys,     // bogus word used by the next burst only
    input  wire        glitch,    // request one bogus burst
    output reg         sdo
);

    reg [2:0]  scl_s;
    reg [4:0]  bitv;
    reg [15:0] idle;
    reg        started;
    reg        gpend;             // a bogus burst has been requested
    reg [15:0] cur;               // word currently being shifted out

    wire scl_fall = scl_s[1] & ~scl_s[0];
    wire sdo_idle = ACTIVE_LOW ? 1'b1 : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_s   <= 3'b111;
            bitv    <= 5'd0;
            idle    <= 16'd0;
            started <= 1'b0;
            gpend   <= 1'b0;
            cur     <= 16'd0;
            sdo     <= sdo_idle;
        end else begin
            scl_s <= {scl_s[1:0], scl};

            if (glitch)
                gpend <= 1'b1;

            if (!scl) begin
                //------------------------------------------------------
                // low phase -- data is set up on the falling edge
                //------------------------------------------------------
                idle <= 16'd0;
                if (scl_fall) begin
                    if (!started) begin
                        started <= 1'b1;
                        bitv    <= 5'd0;
                        cur     <= gpend ? gkeys : keys;
                        gpend   <= 1'b0;
                        sdo     <= ACTIVE_LOW ? ~(gpend ? gkeys[0] : keys[0])
                                              :  (gpend ? gkeys[0] : keys[0]);
                    end else if (bitv != 5'd15) begin
                        bitv <= bitv + 5'd1;
                        sdo  <= ACTIVE_LOW ? ~cur[bitv + 5'd1]
                                           :  cur[bitv + 5'd1];
                    end else begin
                        sdo <= sdo_idle;
                    end
                end
            end else begin
                //------------------------------------------------------
                // high phase -- hold, and watch for a frame restart
                //------------------------------------------------------
                if (idle == IDLE_CLK-1) begin
                    started <= 1'b0;
                    bitv    <= 5'd0;
                    sdo     <= sdo_idle;
                end else begin
                    idle <= idle + 16'd1;
                end
            end
        end
    end

endmodule
