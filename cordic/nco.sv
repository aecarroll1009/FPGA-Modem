// Phase accumulator and angle-path range reduction.
//
// Produces the quadrant (a multiple of 90 degrees) and the residual (the
// remaining angle in [0, pi/2)) for the current sample. Reducing to one
// quadrant before the CORDIC sees it is what lets 16 iterations converge --
// the CORDIC itself only ever rotates by a residual, never a full angle.
//
// residual is the current phase's angle word, not yet negated for either
// mixing direction; a consumer rotating by -residual (down-conversion) or
// +residual (up-conversion) does that sign separately.
//
// phase_en advances the accumulator for the *next* sample. quadrant and
// residual reflect the accumulator's value from *before* that advance, so a
// consumer that samples them on the same cycle it asserts phase_en gets the
// angle for the sample it is accepting right now.
//
// Reference model: cordic/reference/ddc_reference.py, DDC.phase(),
// DDC.angle_word(), and quadrant_split().

`timescale 1ns/1ps

module nco #(
    parameter int PHASE_BITS       = 32,  // M: accumulator width
    parameter int PHASE_TRUNC_BITS = 14,  // N: phase bits reaching the angle path
    parameter int ANG_BITS         = 18   // CORDIC angle width, N zero-padded into it
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      phase_en,
    input  logic [PHASE_BITS-1:0]     phase_inc,

    output logic [1:0]                quadrant,
    output logic [ANG_BITS-3:0]       residual
);

    logic [PHASE_BITS-1:0] phase_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= '0;
        else if (phase_en)
            phase_acc <= phase_acc + phase_inc;
    end

    // Top N bits of the accumulator, zero-padded on the right to ANG_BITS.
    // Kept as an explicit intermediate rather than collapsed into one bit
    // slice, so this stays traceable line-for-line against angle_word().
    logic [ANG_BITS-1:0] angle_word;
    assign angle_word = {phase_acc[PHASE_BITS-1 -: PHASE_TRUNC_BITS],
                          {(ANG_BITS-PHASE_TRUNC_BITS){1'b0}}};

    assign quadrant = angle_word[ANG_BITS-1 -: 2];
    assign residual = angle_word[ANG_BITS-3:0];

endmodule
