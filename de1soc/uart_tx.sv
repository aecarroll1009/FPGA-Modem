// UART transmitter, 8N1, no flow control.
//
// Takes a byte when in_ready is high and shifts it out LSB-first: one start
// bit, eight data, one stop. CLKS_PER_BIT sets the baud rate; 20 is
// 2.5 Mbaud at 50 MHz.

`timescale 1ns/1ps

module uart_tx #(
    parameter int CLKS_PER_BIT = 20
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       in_valid,
    input  logic [7:0] in_byte,
    output logic       in_ready,

    output logic       tx
);

    // start, 8 data, stop
    localparam int NBits    = 10;
    localparam int BitCntW  = $clog2(NBits + 1);
    localparam int TickCntW = $clog2(CLKS_PER_BIT);

    // Holds {stop, data, start} and shifts right; bit 0 is on the wire.
    logic [NBits-1:0]   sr;
    logic [BitCntW-1:0] bits_left;
    logic [TickCntW-1:0] tick;

    assign in_ready = (bits_left == '0);
    assign tx       = sr[0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr        <= '1;      // idle high
            bits_left <= '0;
            tick      <= '0;
        end else if (bits_left == '0) begin
            sr   <= '1;
            tick <= '0;
            if (in_valid) begin
                sr        <= {1'b1, in_byte, 1'b0};
                bits_left <= BitCntW'(NBits);
            end
        end else if (tick == TickCntW'(CLKS_PER_BIT - 1)) begin
            tick      <= '0;
            sr        <= {1'b1, sr[NBits-1:1]};
            bits_left <= bits_left - 1'b1;
        end else begin
            tick <= tick + 1'b1;
        end
    end

endmodule
