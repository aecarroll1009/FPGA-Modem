// Iterative rotation-mode CORDIC core.
//
// Rotates (x_in, y_in) by angle z_in and scales the result by K, driving z
// toward zero over CORDIC_N_ITER cycles, one iteration per clock, with done
// pulsed once the result is valid. Quadrant range reduction to a residual in
// [0, pi/2) happens in the NCO/mixer wrappers that instantiate this core,
// not here. Reference model: cordic/reference/ddc_reference.py,
// cordic_rotate().

`timescale 1ns/1ps
`include "cordic_atan_table.svh"

module cordic_core #(
    parameter int WIDTH = 18   // datapath width for x and y
) (
    input  logic                             clk,
    input  logic                             rst_n,

    input  logic                             start,
    input  logic signed [WIDTH-1:0]          x_in,
    input  logic signed [WIDTH-1:0]          y_in,
    // Signed, in units of one full circle = 2**CORDIC_ANG_BITS. Positive
    // rotates counter-clockwise; seed negative to rotate the other way.
    input  logic signed [`CORDIC_ANG_BITS-1:0] z_in,

    output logic                             busy,
    output logic                             done,
    output logic signed [WIDTH-1:0]          x_out,
    output logic signed [WIDTH-1:0]          y_out,
    output logic signed [`CORDIC_ANG_BITS-1:0] z_out
);

    localparam int IterBits = $clog2(`CORDIC_N_ITER);
    localparam logic [IterBits-1:0] LastIter = IterBits'(`CORDIC_N_ITER - 1);

    typedef enum logic [1:0] {IDLE, RUN, DONE} state_t;
    state_t state;

    logic [IterBits-1:0]              iter;
    logic signed [WIDTH-1:0]          x_reg, y_reg;
    logic signed [`CORDIC_ANG_BITS-1:0] z_reg;

    // Saturating add/sub to a WIDTH-bit signed range, matching sat() in the
    // reference model. Both operands are sign-extended by one guard bit
    // before combining, so the intermediate result is always exact.
    function automatic logic signed [WIDTH-1:0] sat_add(
        input logic signed [WIDTH-1:0] a,
        input logic signed [WIDTH-1:0] b
    );
        logic signed [WIDTH:0] sum;
        logic signed [WIDTH:0] max_val, min_val;
        sum     = {a[WIDTH-1], a} + {b[WIDTH-1], b};
        max_val = (1 <<< (WIDTH-1)) - 1;
        min_val = -(1 <<< (WIDTH-1));
        if (sum > max_val)      sat_add = max_val[WIDTH-1:0];
        else if (sum < min_val) sat_add = min_val[WIDTH-1:0];
        else                    sat_add = sum[WIDTH-1:0];
    endfunction

    function automatic logic signed [WIDTH-1:0] sat_sub(
        input logic signed [WIDTH-1:0] a,
        input logic signed [WIDTH-1:0] b
    );
        logic signed [WIDTH:0] diff;
        logic signed [WIDTH:0] max_val, min_val;
        diff    = {a[WIDTH-1], a} - {b[WIDTH-1], b};
        max_val = (1 <<< (WIDTH-1)) - 1;
        min_val = -(1 <<< (WIDTH-1));
        if (diff > max_val)      sat_sub = max_val[WIDTH-1:0];
        else if (diff < min_val) sat_sub = min_val[WIDTH-1:0];
        else                     sat_sub = diff[WIDTH-1:0];
    endfunction

    // Next-state combinational logic for one CORDIC iteration. z's sign bit
    // selects the rotation direction. z itself is never saturated: its
    // magnitude stays within CORDIC_ANG_BITS by construction for any input
    // the upstream range reduction can produce.
    logic                             sign_neg;
    logic signed [WIDTH-1:0]          x_shift, y_shift;
    logic signed [WIDTH-1:0]          x_next, y_next;
    logic signed [`CORDIC_ANG_BITS-1:0] z_next;

    assign sign_neg = z_reg[`CORDIC_ANG_BITS-1];
    assign x_shift  = x_reg >>> iter;
    assign y_shift  = y_reg >>> iter;

    always_comb begin
        if (!sign_neg) begin
            x_next = sat_sub(x_reg, y_shift);
            y_next = sat_add(y_reg, x_shift);
            z_next = z_reg - CORDIC_ATAN_TABLE[iter];
        end else begin
            x_next = sat_add(x_reg, y_shift);
            y_next = sat_sub(y_reg, x_shift);
            z_next = z_reg + CORDIC_ATAN_TABLE[iter];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            iter  <= '0;
            x_reg <= '0;
            y_reg <= '0;
            z_reg <= '0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        x_reg <= x_in;
                        y_reg <= y_in;
                        z_reg <= z_in;
                        iter  <= '0;
                        state <= RUN;
                    end
                end
                RUN: begin
                    x_reg <= x_next;
                    y_reg <= y_next;
                    z_reg <= z_next;
                    if (iter == LastIter) begin
                        state <= DONE;
                    end else begin
                        iter <= iter + 1'b1;
                    end
                end
                DONE: begin
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    assign busy  = (state == RUN);
    assign done  = (state == DONE);
    assign x_out = x_reg;
    assign y_out = y_reg;
    assign z_out = z_reg;

endmodule
