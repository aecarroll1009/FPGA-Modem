// Seven-segment decoder for the DE1-SoC's HEX displays.
// Segments are active low, so blank is all ones (7'b1111111).
// Bit order is {g, f, e, d, c, b, a}, matching the board's HEXn[6:0].

`timescale 1ns/1ps

module hex7seg (
    input  logic [3:0] value,
    input  logic       blank,
    output logic [6:0] seg
);

    always_comb begin
        if (blank) begin
            seg = 7'b111_1111;
        end else begin
            unique case (value)
                4'h0: seg = 7'b100_0000;
                4'h1: seg = 7'b111_1001;
                4'h2: seg = 7'b010_0100;
                4'h3: seg = 7'b011_0000;
                4'h4: seg = 7'b001_1001;
                4'h5: seg = 7'b001_0010;
                4'h6: seg = 7'b000_0010;
                4'h7: seg = 7'b111_1000;
                4'h8: seg = 7'b000_0000;
                4'h9: seg = 7'b001_0000;
                4'hA: seg = 7'b000_1000;
                4'hB: seg = 7'b000_0011;
                4'hC: seg = 7'b100_0110;
                4'hD: seg = 7'b010_0001;
                4'hE: seg = 7'b000_0110;
                default: seg = 7'b000_1110;  // F
            endcase
        end
    end

endmodule
