// Measures ddc_frontend's sustained throughput in clocks per sample, the
// number the README's rate budget and the FIR's cycle budget are built on.
//
// Holds in_valid high forever, so the only thing gating acceptance is the
// mixer's own busy.
//
// Run via rx/run_throughput.sh.

`timescale 1ns/1ps
`include "ddc_params.svh"

module tb_throughput #(
    parameter int N_SETTLE = 2000   // clocks to run before measuring
);

    logic clk = 0, rst_n;
    logic [PHASE_BITS-1:0]       phase_inc;
    logic                        in_valid;
    logic signed [DATA_BITS-1:0] xi, xq;
    logic                        busy, out_valid;
    logic signed [MIX_BITS-1:0]  mix_i, mix_q;

    // Throughput is direction-independent -- both directions run the same
    // 16 iterations through the same core -- so this measures down-convert.
    ddc_frontend dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .phase_inc   (phase_inc),
        .downconvert (1'b1),
        .in_valid  (in_valid),
        .xi        (xi),
        .xq        (xq),
        .busy      (busy),
        .out_valid (out_valid),
        .mix_i     (mix_i),
        .mix_q     (mix_q)
    );

    always #5 clk <= ~clk;

    // Measured between the first and last output, not from reset, so reset
    // and pipeline-fill cycles do not skew the rate; that also makes cyc's
    // origin irrelevant, so it needs no rst_n gating.
    int cyc = 0, n_out = 0, first_cyc = -1, last_cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (out_valid) begin
            n_out <= n_out + 1;
            if (first_cyc < 0) first_cyc <= cyc;
            last_cyc <= cyc;
        end
    end

    real cps;
    initial begin
        phase_inc = PHASE_INC;
        rst_n = 0; in_valid = 0; xi = 1000; xq = 500;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        in_valid = 1;
        repeat (N_SETTLE) @(posedge clk);
        in_valid = 0;
        repeat (50) @(posedge clk);

        if (n_out < 2) begin
            $display("FAILED: only %0d outputs -- cannot measure a rate", n_out);
            $finish;
        end

        cps = real'(last_cyc - first_cyc) / real'(n_out - 1);
        $display("outputs=%0d over %0d clocks", n_out, last_cyc - first_cyc);
        $display("sustained: %0.2f clocks per sample", cps);
        $display("=> 0.4 MS/s needs a %0.2f MHz clock (mixer alone)", 0.4 * cps);
        $display("=> FIR budget at DECIM=%0d: %0.0f clocks per I/Q output pair",
                 DECIM, cps * DECIM);
        $finish;
    end

endmodule
