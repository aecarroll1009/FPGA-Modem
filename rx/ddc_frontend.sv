// Wires the phase/angle path (nco) to the fused mixer (mixer_fused): input
// samples to IQ output, before any filtering.
//
// `downconvert` selects the direction at run time, so this is the DDC front
// end when high and the DUC's mixer stage when low.
//
// in_valid is ignored while busy is high; accept mix_i/mix_q on out_valid
// and do not assert the next in_valid until busy falls.
//
// Reference model: cordic/reference/ddc_reference.py, DDC.mix_stage().

`timescale 1ns/1ps

module ddc_frontend #(
    parameter int PHASE_BITS       = 24,
    parameter int PHASE_TRUNC_BITS = 14,
    parameter int ANG_BITS         = 17,
    parameter int DATA_BITS        = 16,
    parameter int CORDIC_BITS      = 18,
    parameter int MIX_BITS         = 17
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic [PHASE_BITS-1:0]       phase_inc,

    // 1 = down-convert (RX), 0 = up-convert (TX). Sampled per accepted
    // sample, so it may change between samples.
    input  logic                        downconvert,

    input  logic                        in_valid,
    input  logic signed [DATA_BITS-1:0] xi,
    input  logic signed [DATA_BITS-1:0] xq,

    output logic                        busy,
    output logic                        out_valid,
    output logic signed [MIX_BITS-1:0]  mix_i,
    output logic signed [MIX_BITS-1:0]  mix_q
);

    logic                accept;
    logic [1:0]          quadrant;
    logic [ANG_BITS-3:0] residual;

    assign accept = in_valid && !busy;

    nco #(
        .PHASE_BITS       (PHASE_BITS),
        .PHASE_TRUNC_BITS (PHASE_TRUNC_BITS),
        .ANG_BITS         (ANG_BITS)
    ) u_nco (
        .clk       (clk),
        .rst_n     (rst_n),
        .phase_en  (accept),
        .phase_inc (phase_inc),
        .quadrant  (quadrant),
        .residual  (residual)
    );

    mixer_fused #(
        .DATA_BITS   (DATA_BITS),
        .CORDIC_BITS (CORDIC_BITS),
        .MIX_BITS    (MIX_BITS),
        .ANG_BITS    (ANG_BITS)
    ) u_mixer (
        .clk         (clk),
        .rst_n       (rst_n),
        .downconvert (downconvert),
        .in_valid    (accept),
        .xi          (xi),
        .xq          (xq),
        .quadrant    (quadrant),
        .residual    (residual),
        .busy        (busy),
        .out_valid   (out_valid),
        .mix_i       (mix_i),
        .mix_q       (mix_q)
    );

endmodule
