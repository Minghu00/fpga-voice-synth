//=============================================================================
// i2s_tx.v  --  standard Philips I2S transmitter, 16-bit slots (32 bit/frame)
//
//  Timing derived from the audio frame counter, so it can never drift:
//      BCLK_HALF = 35 clk  -> BCLK = 108 MHz / 70 = 1.5429 MHz
//      32 bits/frame       -> 32 * 2 * 35 = 2240 clk = one audio frame
//      fs = 108 MHz / 2240 = 48 214.2857 Hz
//
//  Format (MAX98357 / PT8211 compatible)
//      LRCK = 0 -> left channel,  LRCK = 1 -> right channel
//      MSB first, two's complement.
//      din is driven while BCLK is LOW and held while BCLK is HIGH, so it is
//      stable on every BCLK rising edge -- that is where the DAC latches.
//
//  RELOAD
//      audio_out.v raises load_tick when a fresh mixed sample is ready.  It is
//      captured into a shadow pair immediately, and the shadow is copied into
//      the two shift words at the slot boundary.  The transmitter therefore
//      always sends a COMPLETE frame -- never a half-updated one -- and the
//      capture instant no longer depends on where the bit counter happens to
//      be when the new sample arrives.
//
//  FOUR REAL BUGS FOUND ON HARDWARE, kept as warnings:
//   1. LRCK was set to 1 at bit 15 and never cleared, so from the second frame
//      onwards the transmitter sat in the RIGHT slot for ever; the DAC then
//      latched only zeros and the board was silent while the display showed a
//      perfect waveform.  LRCK must be cleared again at the frame boundary.
//   2. A single 32 bit shift register silently drops the last LSB of the left
//      word.  The two words are therefore reloaded as a pair and selected by
//      a bit index instead of being shifted into each other.
//   3. Reload was applied without looking at BCLK, so it could tear a slot in
//      half and shift the whole word left by one bit.  Reload only happens at
//      a falling BCLK edge, which is always a slot boundary.
//   4. There used to be a separate S_IDLE state that cost ONE EXTRA CLOCK per
//      frame: the transmitter cycled in 2241 clk while the audio frame is
//      2240, so the sample-to-bits phase slid by one clock every frame and
//      re-synchronised with a click roughly every 46 ms.  The reload now
//      happens inside the falling edge that ends bit 31, so a frame is
//      exactly 32 * 2 * BCLK_HALF = 2240 clk and stays locked.
//
//  NOTE ON LRCK_EARLY
//      The old parameter set lrclk = 1 at EVERY slot start, i.e. both channels,
//      which would have broken the format outright.  Philips I2S wants LRCK to
//      change half a BCLK before the MSB, and since din and lrclk here both
//      change on the same falling edge that condition is already met for a
//      DAC that latches on the rising edge; the parameter is removed rather
//      than left as a trap.
//=============================================================================
`timescale 1ns / 1ps

module i2s_tx #(
    parameter integer BCLK_HALF = 35       // clk per BCLK half period
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] fc,             // audio frame counter (informational)
    input  wire        load_tick,      // 1 clk pulse: latch sample_l/r now
    input  wire [15:0] sample_l,
    input  wire [15:0] sample_r,
    output reg         bclk,
    output reg         lrclk,
    output reg         din
);

    localparam [0:0] S_LOW  = 1'b0;     // BCLK low,  counting up to the rising edge
    localparam [0:0] S_HIGH = 1'b1;     // BCLK high, din is being latched

    reg        st;
    reg [5:0]  half;
    reg [5:0]  bitn;                // index of the bit on the wire, 0..31
    reg [15:0] cur;                 // left  word being sent
    reg [15:0] nx;                  // right word
    reg [15:0] shadow_l, shadow_r;  // captured on load_tick

    wire [5:0] BCLK_HALF_M1 = BCLK_HALF - 1;

    //--------------------------------------------------------------
    // sample capture: independent of the bit stream, so a load_tick
    // that lands mid-slot is never lost and never tears the word
    //--------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_l <= 16'd0;
            shadow_r <= 16'd0;
        end else if (load_tick) begin
            shadow_l <= sample_l;
            shadow_r <= sample_r;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Start as if the last bit of a frame had just ended, so the very
            // first clock performs the frame-boundary reload below and the
            // first frame is complete instead of starting with a zero MSB.
            st    <= S_HIGH;
            half  <= BCLK_HALF - 1;
            bitn  <= 6'd31;
            cur   <= 16'd0;
            nx    <= 16'd0;
            bclk  <= 1'b0;
            lrclk <= 1'b0;
            din   <= 1'b0;
        end else begin
            case (st)
            //--------------------------------------------------------
            // Low half of BCLK: din is already valid, the DAC will
            // latch it on the rising edge produced at the end.
            //--------------------------------------------------------
            S_LOW: begin
                if (half == BCLK_HALF_M1[5:0]) begin
                    bclk <= 1'b1;                  // rising edge, DAC latches
                    half <= 6'd0;
                    st   <= S_HIGH;
                end else begin
                    half <= half + 6'd1;
                end
            end
            //--------------------------------------------------------
            // High half of BCLK: din must not move.  On the falling edge
            // pick the next bit, and after bit 31 reload the next frame
            // right here -- that is what makes the frame exactly
            // 32 * 2 * BCLK_HALF clocks long.
            //--------------------------------------------------------
            default: begin
                if (half == BCLK_HALF_M1[5:0]) begin
                    bclk <= 1'b0;                  // falling edge
                    half <= 6'd0;
                    st   <= S_LOW;                 // back to the low half.
                                                   // WITHOUT THIS the FSM stays
                                                   // in S_HIGH, bclk is driven
                                                   // low for ever and the DAC
                                                   // never sees a single clock.
                    if (bitn >= 6'd31) begin
                        // frame boundary: left word starts here
                        bitn  <= 6'd0;
                        cur   <= shadow_l;
                        nx    <= shadow_r;
                        din   <= shadow_l[15];
                        lrclk <= 1'b0;             // left slot
                    end else begin
                        bitn <= bitn + 6'd1;
                        if (bitn == 6'd15) begin
                            lrclk <= 1'b1;                     // right slot MSB
                            din   <= nx[15];
                        end else if (bitn < 6'd15) begin
                            din   <= cur[14 - bitn[3:0]];      // cur bit bitn+1
                        end else begin
                            // right word, bitn 16..30 -> nx[14..0]
                            din   <= nx[5'd14 - {1'b0, bitn[3:0]}];
                        end
                    end
                end else begin
                    half <= half + 6'd1;
                end
            end
            endcase
        end
    end

endmodule
