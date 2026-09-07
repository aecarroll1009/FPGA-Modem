// Synchronous byte FIFO, DEPTH entries, DEPTH a power of two.
//
// Buffers the framer's header bursts ahead of the UART. Reads are
// combinational: rd_data holds the front entry whenever empty is low.

`timescale 1ns/1ps

module byte_fifo #(
    parameter int DEPTH = 32
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       wr_en,
    input  logic [7:0] wr_data,
    output logic       full,

    input  logic       rd_en,
    output logic [7:0] rd_data,
    output logic       empty
);

    localparam int AddrW = $clog2(DEPTH);

    // One bit wider than the address, to represent DEPTH itself.
    localparam int CntW = AddrW + 1;

    logic [7:0]       mem [0:DEPTH-1];
    logic [AddrW-1:0] wr_ptr, rd_ptr;
    logic [CntW-1:0]  count;

    assign empty   = (count == CntW'(0));
    assign full    = (count == CntW'(DEPTH));
    assign rd_data = mem[rd_ptr];

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always_ff @(posedge clk) begin
        if (do_wr) mem[wr_ptr] <= wr_data;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;   // wraps mod DEPTH
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;

            case ({do_wr, do_rd})
                2'b10:   count <= count + CntW'(1);
                2'b01:   count <= count - CntW'(1);
                default: count <= count;
            endcase
        end
    end

endmodule
