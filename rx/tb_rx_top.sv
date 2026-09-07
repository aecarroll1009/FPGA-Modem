// Self-checking testbench for rx_top: the full chain, ADC-rate stimulus in,
// baseband IQ out.
//
// Neither fir_decimate.sv nor ddc_frontend.sv is checked against out_i/out_q
// in combination anywhere else -- tb_ddc_frontend.sv stops at mix_i/mix_q,
// and tb_fir_decimate.sv starts from mix_i/mix_q rather than real ADC
// samples. This is the one testbench that exercises the handshake between
// them: whether ddc_frontend's out_valid pulse is something fir_decimate
// actually samples correctly on the same cycle, not just a shape either
// block assumes about the other.
//
// out_ready is held high throughout; out_overflow's meaning (a consumer that
// stalled) is rx_top's, not this chain's, so it is checked only for staying
// low, not exercised.
//
// Run via rx/run_sim_rx_top.sh.

`timescale 1ns/1ps
`include "ddc_params.svh"

module tb_rx_top;

    logic clk = 0, rst_n;

    logic [PHASE_BITS-1:0]        phase_inc;
    logic                         in_valid;
    logic                         in_ready;
    logic signed [DATA_BITS-1:0]  adc_i, adc_q;
    logic                         out_valid;
    logic                         out_ready;
    logic signed [OUT_BITS-1:0]   iq_i, iq_q;
    logic                         out_overflow;

    rx_top #(
        .PHASE_BITS       (PHASE_BITS),
        .PHASE_TRUNC_BITS (PHASE_TRUNC_BITS),
        .ANG_BITS         (ANG_BITS),
        .DATA_BITS        (DATA_BITS),
        .CORDIC_BITS      (CORDIC_BITS),
        .MIX_BITS         (MIX_BITS),
        .DECIM            (DECIM),
        .ACC_BITS         (ACC_BITS),
        .OUT_BITS         (OUT_BITS)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .phase_inc    (phase_inc),
        .in_valid     (in_valid),
        .in_ready     (in_ready),
        .adc_i        (adc_i),
        .adc_q        (adc_q),
        .out_valid    (out_valid),
        .out_ready    (out_ready),
        .iq_i         (iq_i),
        .iq_q         (iq_q),
        .out_overflow (out_overflow)
    );

    always #5 clk <= ~clk;

    logic signed [DATA_BITS-1:0] stim_i [0:N_STIM-1];
    logic signed [DATA_BITS-1:0] stim_q [0:N_STIM-1];
    logic signed [OUT_BITS-1:0]  out_i_exp [0:N_OUT-1];
    logic signed [OUT_BITS-1:0]  out_q_exp [0:N_OUT-1];

    int n_fail = 0;
    int n_out  = 0;

    initial begin
        $readmemh("build/ddc_vectors/stim_i.hex", stim_i);
        $readmemh("build/ddc_vectors/stim_q.hex", stim_q);
        $readmemh("build/ddc_vectors/out_i.hex",  out_i_exp);
        $readmemh("build/ddc_vectors/out_q.hex",  out_q_exp);

        phase_inc = PHASE_INC;
        out_ready = 1'b1;
        rst_n = 0;
        in_valid = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fork
            begin : producer
                for (int i = 0; i < N_STIM; i++) begin
                    adc_i = stim_i[i];
                    adc_q = stim_q[i];
                    in_valid = 1;
                    @(posedge clk);   // DUT is idle here, so this edge always accepts
                    in_valid = 0;
                    while (!in_ready) @(posedge clk);   // ddc_frontend's real backpressure
                end
            end

            begin : consumer
                while (n_out < N_OUT) begin
                    @(posedge clk);
                    if (out_overflow) begin
                        n_fail++;
                        $display("FAIL: out_overflow latched -- egress dropped a sample");
                        break;
                    end
                    if (out_valid) begin
                        if (iq_i !== out_i_exp[n_out] || iq_q !== out_q_exp[n_out]) begin
                            n_fail++;
                            if (n_fail <= 10) begin
                                $display("FAIL output %0d", n_out);
                                $display("  expected iq_i=%0d iq_q=%0d", out_i_exp[n_out], out_q_exp[n_out]);
                                $display("  got      iq_i=%0d iq_q=%0d", iq_i, iq_q);
                            end
                        end
                        n_out++;
                    end
                end
            end
        join

        if (n_fail == 0 && n_out == N_OUT)
            $display("ALL %0d END-TO-END OUTPUTS PASSED", N_OUT);
        else begin
            $display("%0d of %0d END-TO-END OUTPUTS FAILED (%0d produced)", n_fail, N_OUT, n_out);
            $fatal(1, "tb_rx_top: %0d of %0d outputs failed (%0d produced)", n_fail, N_OUT, n_out);
        end

        $finish;
    end

endmodule
