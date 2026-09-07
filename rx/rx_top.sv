// Synthesizable top level for the RX chain: ADC-rate IQ in, baseband IQ out.
// Built by the Quartus flow in syn/ (see syn/build.tcl).
//
// Egress is a stub valid/ready stream since the physical link is not chosen
// yet; syn/rx_top.sdc false-paths that I/O.
//
// out_ready is an observation point, not a brake: neither ddc_frontend nor
// fir_decimate can be stalled once they accept a sample, so a consumer that
// deasserts out_ready while out_valid is high loses that sample and
// latches out_overflow.

`timescale 1ns/1ps

module rx_top #(
    parameter int PHASE_BITS       = 24,
    parameter int PHASE_TRUNC_BITS = 14,
    parameter int ANG_BITS         = 17,
    parameter int DATA_BITS        = 16,
    parameter int CORDIC_BITS      = 18,
    parameter int MIX_BITS         = 17,
    parameter int DECIM            = 8,
    parameter int ACC_BITS         = 40,
    parameter int OUT_BITS         = 16
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Frequency control. Static in normal operation; a register interface
    // replaces this port once there is one.
    input  logic [PHASE_BITS-1:0]       phase_inc,

    // ADC-side input stream. in_ready is real backpressure: the CORDIC is
    // iterative, so the front end absorbs one sample per rotation, not one
    // per clock.
    input  logic                        in_valid,
    output logic                        in_ready,
    input  logic signed [DATA_BITS-1:0] adc_i,
    input  logic signed [DATA_BITS-1:0] adc_q,

    // Baseband IQ egress (stub interface -- see the header note). Runs at
    // fs_in/DECIM, not fs_in -- one valid pulse per FIR output, not per
    // mixer output.
    output logic                        out_valid,
    input  logic                        out_ready,
    output logic signed [OUT_BITS-1:0]  iq_i,
    output logic signed [OUT_BITS-1:0]  iq_q,
    output logic                        out_overflow
);

    logic busy;
    logic mix_valid;
    logic signed [MIX_BITS-1:0] mix_i, mix_q;

    assign in_ready = !busy;

    ddc_frontend #(
        .PHASE_BITS       (PHASE_BITS),
        .PHASE_TRUNC_BITS (PHASE_TRUNC_BITS),
        .ANG_BITS         (ANG_BITS),
        .DATA_BITS        (DATA_BITS),
        .CORDIC_BITS      (CORDIC_BITS),
        .MIX_BITS         (MIX_BITS)
    ) u_ddc (
        .clk         (clk),
        .rst_n       (rst_n),
        .phase_inc   (phase_inc),
        // This top level is the RX chain, so the shared front end is tied to
        // down-convert here. The TT wrapper drives it from a pin instead.
        .downconvert (1'b1),
        .in_valid    (in_valid),
        .xi          (adc_i),
        .xq          (adc_q),
        .busy        (busy),
        .out_valid   (mix_valid),
        .mix_i       (mix_i),
        .mix_q       (mix_q)
    );

    // -- egress ------------------------------------------------------------
    logic fir_valid;
    logic signed [OUT_BITS-1:0] fir_i, fir_q;

    fir_decimate #(
        .IN_BITS  (MIX_BITS),
        .DECIM    (DECIM),
        .ACC_BITS (ACC_BITS),
        .OUT_BITS (OUT_BITS)
    ) u_fir (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (mix_valid),
        .xi        (mix_i),
        .xq        (mix_q),
        .out_valid (fir_valid),
        .out_i     (fir_i),
        .out_q     (fir_q)
    );

    assign out_valid = fir_valid;
    assign iq_i      = fir_i;
    assign iq_q      = fir_q;

    // Sticky: a consumer that could not take a sample dropped it.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_overflow <= 1'b0;
        else if (out_valid && !out_ready)
            out_overflow <= 1'b1;
    end

endmodule
