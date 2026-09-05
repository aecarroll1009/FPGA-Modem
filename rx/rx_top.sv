// Synthesizable top level for the RX chain: ADC-rate IQ in, baseband IQ out.
//
// This is the unit the Quartus flow in syn/ builds, and it exists so that the
// rate budget in the README is checked against a real device rather than only
// against simulation. See syn/build.tcl.
//
// Egress is deliberately a stub. The physical link (USB, Ethernet, an SoC
// bridge) is not chosen yet, so the output is a plain valid/ready stream and
// syn/rx_top.sdc false-paths the I/O. Real I/O constraints arrive with the PHY.
//
// The decimating FIR is not in the datapath yet -- mixer output currently goes
// straight to the egress stream, so this build measures the CORDIC path alone.
// The FIR inserts between u_ddc and the output, narrowing MIX_BITS to OUT_BITS
// and dropping the sample rate by DECIM.
//
// Backpressure: ddc_frontend cannot be stalled once it has accepted a sample,
// so out_ready does NOT gate the datapath -- it is an observation point, not a
// brake. A consumer that deasserts out_ready while out_valid is high loses that
// sample and latches out_overflow. Keeping up is a system requirement (the
// budget is in the README); out_overflow is how a violation becomes visible
// instead of silently corrupting the band.

`timescale 1ns/1ps

module rx_top #(
    parameter int PHASE_BITS       = 32,
    parameter int PHASE_TRUNC_BITS = 14,
    parameter int ANG_BITS         = 18,
    parameter int DATA_BITS        = 16,
    parameter int CORDIC_BITS      = 20,
    parameter int MIX_BITS         = 17
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

    // Baseband IQ egress (stub interface -- see the header note).
    output logic                        out_valid,
    input  logic                        out_ready,
    output logic signed [MIX_BITS-1:0]  iq_i,
    output logic signed [MIX_BITS-1:0]  iq_q,
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
        .clk       (clk),
        .rst_n     (rst_n),
        .phase_inc (phase_inc),
        .in_valid  (in_valid),
        .xi        (adc_i),
        .xq        (adc_q),
        .busy      (busy),
        .out_valid (mix_valid),
        .mix_i     (mix_i),
        .mix_q     (mix_q)
    );

    // -- egress ------------------------------------------------------------
    // The decimating FIR goes here.
    assign out_valid = mix_valid;
    assign iq_i      = mix_i;
    assign iq_q      = mix_q;

    // Sticky: a consumer that could not take a sample dropped it.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_overflow <= 1'b0;
        else if (out_valid && !out_ready)
            out_overflow <= 1'b1;
    end

endmodule
