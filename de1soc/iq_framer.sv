// Serialises decimated IQ pairs into the byte stream in docs/iq_format.md.
//
// Every SAMPLES_PER_FRAME-th pair carries a 4-byte magic and a 16-bit frame
// counter ahead of it. Each pair emits as four big-endian bytes: I high, I
// low, Q high, Q low.

`timescale 1ns/1ps

module iq_framer #(
    parameter int DATA_BITS         = 16,
    parameter int SAMPLES_PER_FRAME = 64
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        in_valid,
    input  logic signed [DATA_BITS-1:0] in_i,
    input  logic signed [DATA_BITS-1:0] in_q,

    output logic                        out_valid,
    output logic [7:0]                  out_byte,
    input  logic                        out_ready,

    // Sticky: a pair arrived mid-serialisation and was dropped. Ordinary
    // backpressure on out_ready is not counted here.
    output logic                        overflow,

    // The counter the next frame header will carry.
    output logic [15:0]                 frame_count
);

    localparam logic [7:0] Magic0 = 8'h53;   // 'S'
    localparam logic [7:0] Magic1 = 8'h44;   // 'D'
    localparam logic [7:0] Magic2 = 8'h52;   // 'R'
    localparam logic [7:0] Magic3 = 8'h01;   // format version

    // Fixed by the wire format: 4 magic + 2 sequence, then 2 each of I and Q.
    localparam int HeaderBytes  = 6;
    localparam int PayloadBytes = 4;
    localparam int MaxBytes     = HeaderBytes + PayloadBytes;

    localparam int SelW = 4;              // holds 0..MaxBytes-1
    localparam int CntW = 5;              // holds 0..MaxBytes
    localparam int PosW = $clog2(SAMPLES_PER_FRAME);

    logic signed [DATA_BITS-1:0] i_reg, q_reg;
    logic [15:0]                 seq;
    logic [PosW-1:0]             frame_pos;

    assign frame_count = seq;

    // Bytes still owed for the current pair; zero means idle. Starts at
    // MaxBytes with a header, PayloadBytes without.
    logic [CntW-1:0] bytes_left;

    wire busy = (bytes_left != '0);

    // Position in the 10-byte template; a headerless pair starts at 6.
    wire [SelW-1:0] sel = SelW'(CntW'(MaxBytes) - bytes_left);

    always_comb begin
        unique case (sel)
            4'd0:    out_byte = Magic0;
            4'd1:    out_byte = Magic1;
            4'd2:    out_byte = Magic2;
            4'd3:    out_byte = Magic3;
            4'd4:    out_byte = seq[15:8];
            4'd5:    out_byte = seq[7:0];
            4'd6:    out_byte = i_reg[DATA_BITS-1 -: 8];
            4'd7:    out_byte = i_reg[DATA_BITS-9 -: 8];
            4'd8:    out_byte = q_reg[DATA_BITS-1 -: 8];
            default: out_byte = q_reg[DATA_BITS-9 -: 8];
        endcase
    end

    assign out_valid = busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_reg      <= '0;
            q_reg      <= '0;
            seq        <= '0;
            frame_pos  <= '0;
            bytes_left <= '0;
            overflow   <= 1'b0;
        end else begin
            if (busy && out_ready)
                bytes_left <= bytes_left - 1'b1;

            if (in_valid) begin
                if (busy) begin
                    // Previous pair still going out; drop rather than tear.
                    overflow <= 1'b1;
                end else begin
                    i_reg      <= in_i;
                    q_reg      <= in_q;
                    bytes_left <= (frame_pos == '0)
                                ? CntW'(MaxBytes)
                                : CntW'(PayloadBytes);
                    if (frame_pos == PosW'(SAMPLES_PER_FRAME - 1)) begin
                        frame_pos <= '0;
                        seq       <= seq + 1'b1;
                    end else begin
                        frame_pos <= frame_pos + 1'b1;
                    end
                end
            end
        end
    end

endmodule
