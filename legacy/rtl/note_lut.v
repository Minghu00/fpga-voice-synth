`timescale 1ns / 1ps

module note_lut (
    input  wire [1:0]  idx,
    output reg  [31:0] tw
);

    always @(*) begin
        case (idx)
            2'd0:    tw = 32'h0165A690;
            2'd1:    tw = 32'h01C29C8F;
            2'd2:    tw = 32'h0217DED7;
            default: tw = 32'h02CB4D1F;
        endcase
    end

endmodule
