// Self-checking testbench for tx_top: the full TX chain, baseband-rate
// stimulus in, RF-rate IQ out.
//
// Neither fir_interpolate.sv nor mixer_fused.sv is checked against
// tx_mix_i/tx_mix_q anywhere else -- tb_fir_interpolate.sv stops at
// interp_i/interp_q, and the up-convert mixer tests in
// test_ddc_reference.py never run through a real interpolator. This is the
// one testbench exercising the elastic queue described in tx_top.sv's
// header: whether the interpolator's fast burst of INTERP outputs actually
// survives being drained into the mixer's much slower, iterative pace
// without a sample being dropped, duplicated, or reordered.
//
// Run via tx/run_sim_tx_top.sh.

`timescale 1ns/1ps
`include "ddc_params.svh"

module tb_tx_top;

    logic clk = 0, rst_n;

    logic [PHASE_BITS-1:0]        phase_inc;
    logic                         in_valid;
    logic                         in_ready;
    logic signed [DATA_BITS-1:0]  bb_i, bb_q;
    logic                         out_valid;
    logic                         out_ready;
    logic signed [MIX_BITS-1:0]   rf_i, rf_q;
    logic                         out_overflow;

    tx_top #(
        .PHASE_BITS       (PHASE_BITS),
        .PHASE_TRUNC_BITS (PHASE_TRUNC_BITS),
        .ANG_BITS         (ANG_BITS),
        .DATA_BITS        (DATA_BITS),
        .CORDIC_BITS      (CORDIC_BITS),
        .MIX_BITS         (MIX_BITS),
        .ACC_BITS         (ACC_BITS)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .phase_inc    (phase_inc),
        .in_valid     (in_valid),
        .in_ready     (in_ready),
        .bb_i         (bb_i),
        .bb_q         (bb_q),
        .out_valid    (out_valid),
        .out_ready    (out_ready),
        .rf_i         (rf_i),
        .rf_q         (rf_q),
        .out_overflow (out_overflow)
    );

    always #5 clk <= ~clk;

    logic signed [DATA_BITS-1:0] stim_i [0:N_TX_STIM-1];
    logic signed [DATA_BITS-1:0] stim_q [0:N_TX_STIM-1];
    logic signed [MIX_BITS-1:0]  mix_i_exp [0:N_INTERP_OUT-1];
    logic signed [MIX_BITS-1:0]  mix_q_exp [0:N_INTERP_OUT-1];

    int n_fail = 0;
    int n_out  = 0;

    initial begin
        $readmemh("build/ddc_vectors/tx_stim_i.hex", stim_i);
        $readmemh("build/ddc_vectors/tx_stim_q.hex", stim_q);
        $readmemh("build/ddc_vectors/tx_mix_i.hex",  mix_i_exp);
        $readmemh("build/ddc_vectors/tx_mix_q.hex",  mix_q_exp);

        phase_inc = PHASE_INC;
        out_ready = 1'b1;
        rst_n = 0;
        in_valid = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fork
            begin : producer
                for (int i = 0; i < N_TX_STIM; i++) begin
                    bb_i = stim_i[i];
                    bb_q = stim_q[i];
                    in_valid = 1;
                    @(posedge clk);   // DUT is idle here, so this edge always accepts
                    in_valid = 0;
                    while (!in_ready) @(posedge clk);
                end
            end

            begin : consumer
                while (n_out < N_INTERP_OUT) begin
                    @(posedge clk);
                    if (out_overflow) begin
                        n_fail++;
                        $display("FAIL: out_overflow latched -- egress dropped a sample");
                        break;
                    end
                    if (out_valid) begin
                        if (rf_i !== mix_i_exp[n_out] || rf_q !== mix_q_exp[n_out]) begin
                            n_fail++;
                            if (n_fail <= 10) begin
                                $display("FAIL output %0d", n_out);
                                $display("  expected rf_i=%0d rf_q=%0d", mix_i_exp[n_out], mix_q_exp[n_out]);
                                $display("  got      rf_i=%0d rf_q=%0d", rf_i, rf_q);
                            end
                        end
                        n_out++;
                    end
                end
            end
        join

        if (n_fail == 0 && n_out == N_INTERP_OUT)
            $display("ALL %0d TX END-TO-END OUTPUTS PASSED", N_INTERP_OUT);
        else begin
            $display("%0d of %0d TX END-TO-END OUTPUTS FAILED (%0d produced)", n_fail, N_INTERP_OUT, n_out);
            $fatal(1, "tb_tx_top: %0d of %0d outputs failed (%0d produced)", n_fail, N_INTERP_OUT, n_out);
        end

        $finish;
    end

endmodule
