// Phase accumulator and angle-path range reduction.
//
// Produces the quadrant (0-3, a multiple of 90 degrees) and the residual
// (the remaining angle in [0, pi/2)) for the current sample. quadrant and
// residual reflect the accumulator's value from before phase_en's advance,
// so a consumer sampling them the same cycle it asserts phase_en gets the
// angle for the sample it is accepting. Reference model:
// cordic/reference/ddc_reference.py, DDC.phase(), DDC.angle_word().

`timescale 1ns/1ps

module nco #(
    parameter int PHASE_BITS       = 24,  // M: accumulator width
    parameter int PHASE_TRUNC_BITS = 14,  // N: phase bits reaching the angle path
    parameter int ANG_BITS         = 17   // CORDIC angle width, N zero-padded into it
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      phase_en,
    input  logic [PHASE_BITS-1:0]     phase_inc,

    output logic [1:0]                quadrant,
    // Not yet negated for either mixing direction; a consumer rotating by
    // -residual (down-conversion) or +residual (up-conversion) applies that
    // sign itself.
    output logic [ANG_BITS-3:0]       residual
);

    logic [PHASE_BITS-1:0] phase_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= '0;
        else if (phase_en)
            phase_acc <= phase_acc + phase_inc;
    end

    // Top N bits of the accumulator, zero-padded on the right to ANG_BITS,
    // matching angle_word() in the reference model.
    logic [ANG_BITS-1:0] angle_word;
    assign angle_word = {phase_acc[PHASE_BITS-1 -: PHASE_TRUNC_BITS],
                          {(ANG_BITS-PHASE_TRUNC_BITS){1'b0}}};

    assign quadrant = angle_word[ANG_BITS-1 -: 2];
    assign residual = angle_word[ANG_BITS-3:0];

endmodule
