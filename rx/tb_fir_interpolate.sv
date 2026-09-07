// Self-checking testbench for fir_interpolate.
//
// Drives the TX baseband stimulus (build/ddc_vectors/tx_stim_i.hex, at the
// pre-interpolation rate) in one sample at a time, and checks every one of
// the INTERP outputs each input produces, in order, against interp_i.hex --
// the reference model's own fir_interpolate() output, which is INTERP times
// longer than the stimulus. Since the RTL is a polyphase realization and the
// reference is the direct zero-stuffed one, this is also the test that would
// catch a wrong INTERP*n+p indexing, not just a wrong tap value.
//
// Run via rx/run_sim_fir_interp.sh, which regenerates the vectors and the
// coefficient table first so the RTL and the checked values can never drift
// apart.

`timescale 1ns/1ps
`include "ddc_params.svh"

module tb_fir_interpolate;

    logic clk = 0, rst_n;

    logic                        in_valid;
    logic signed [DATA_BITS-1:0] xi, xq;
    logic                        in_ready;
    logic                        out_valid;
    logic signed [DATA_BITS-1:0] out_i, out_q;

    fir_interpolate #(
        .DATA_BITS (DATA_BITS),
        .ACC_BITS  (ACC_BITS)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .xi        (xi),
        .xq        (xq),
        .in_ready  (in_ready),
        .out_valid (out_valid),
        .out_i     (out_i),
        .out_q     (out_q)
    );

    always #5 clk <= ~clk;

    logic signed [DATA_BITS-1:0] stim_i [0:N_TX_STIM-1];
    logic signed [DATA_BITS-1:0] stim_q [0:N_TX_STIM-1];
    logic signed [DATA_BITS-1:0] interp_i_exp [0:N_INTERP_OUT-1];
    logic signed [DATA_BITS-1:0] interp_q_exp [0:N_INTERP_OUT-1];

    int n_fail = 0;
    int n_out  = 0;

    initial begin
        $readmemh("build/ddc_vectors/tx_stim_i.hex", stim_i);
        $readmemh("build/ddc_vectors/tx_stim_q.hex", stim_q);
        $readmemh("build/ddc_vectors/interp_i.hex",  interp_i_exp);
        $readmemh("build/ddc_vectors/interp_q.hex",  interp_q_exp);

        rst_n = 0;
        in_valid = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fork
            begin : producer
                for (int i = 0; i < N_TX_STIM; i++) begin
                    xi = stim_i[i];
                    xq = stim_q[i];
                    in_valid = 1;
                    @(posedge clk);   // DUT is idle here, so this edge always accepts
                    in_valid = 0;
                    while (!in_ready) @(posedge clk);
                end
            end

            begin : consumer
                while (n_out < N_INTERP_OUT) begin
                    @(posedge clk);
                    if (out_valid) begin
                        if (out_i !== interp_i_exp[n_out] || out_q !== interp_q_exp[n_out]) begin
                            n_fail++;
                            if (n_fail <= 10) begin
                                $display("FAIL output %0d", n_out);
                                $display("  expected out_i=%0d out_q=%0d", interp_i_exp[n_out], interp_q_exp[n_out]);
                                $display("  got      out_i=%0d out_q=%0d", out_i, out_q);
                            end
                        end
                        n_out++;
                    end
                end
            end
        join

        if (n_fail == 0 && n_out == N_INTERP_OUT)
            $display("ALL %0d OUTPUTS PASSED", N_INTERP_OUT);
        else begin
            $display("%0d of %0d OUTPUTS FAILED (%0d produced)", n_fail, N_INTERP_OUT, n_out);
            $fatal(1, "tb_fir_interpolate: %0d of %0d outputs failed (%0d produced)", n_fail, N_INTERP_OUT, n_out);
        end

        $finish;
    end

endmodule
