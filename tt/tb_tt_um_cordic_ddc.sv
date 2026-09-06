// Self-checking testbench for the TinyTapeout wrapper.
//
// Drives the real byte-serial protocol -- config bytes, then four sample bytes
// per rotation -- and reassembles the five result bytes, checking them against
// the same mix_i/mix_q vectors the parallel testbench uses. If the serialised
// interface loses, reorders, or misaligns a byte, this fails.
//
// It also measures the cost of serialisation, which is the reason the wrapper
// exists: bytes moved per sample versus clocks per sample.
//
// Run via tt/run_sim_tt.sh.

`timescale 1ns/1ps
`include "ddc_params.svh"

module tb_tt_um_cordic_ddc #(
    parameter string VEC_DIR = "build/ddc_vectors",
    parameter int    N_TEST  = 512     // rotations to check
);

    localparam int SampBytes = (2 * DATA_BITS) / 8;
    localparam int OutBits   = 2 * MIX_BITS;
    localparam int OutBytes  = (OutBits + 7) / 8;
    localparam int CfgBytes  = PHASE_BITS / 8;

    logic clk = 0, rst_n;
    logic [7:0] ui_in, uio_in;
    wire  [7:0] uo_out, uio_out, uio_oe;

    tt_um_cordic_ddc dut (
        .ui_in   (ui_in),
        .uo_out  (uo_out),
        .uio_in  (uio_in),
        .uio_out (uio_out),
        .uio_oe  (uio_oe),
        .ena     (1'b1),
        .clk     (clk),
        .rst_n   (rst_n)
    );

    always #5 clk <= ~clk;

    wire o_valid = uio_out[2];
    wire i_ready = uio_out[3];
    wire o_ovf   = uio_out[4];

    logic signed [DATA_BITS-1:0] stim_i [0:N_STIM-1];
    logic signed [DATA_BITS-1:0] stim_q [0:N_STIM-1];
    logic signed [MIX_BITS-1:0]  mix_i_exp [0:N_STIM-1];
    logic signed [MIX_BITS-1:0]  mix_q_exp [0:N_STIM-1];

    int n_fail = 0;
    int bytes_in = 0, bytes_out = 0;

    // Free-running and ungated, so rst_n stays a purely asynchronous net (the
    // DUT resets on it asynchronously). The measurement brackets the sample
    // loop instead, which also excludes reset and config from the average.
    int clocks = 0;
    always @(posedge clk) clocks <= clocks + 1;
    int t_start, t_end;

    // Send one byte, holding it until the DUT can take it.
    task automatic send_byte(input logic [7:0] b, input logic is_cfg);
        begin
            if (!is_cfg) while (!i_ready) @(posedge clk);
            ui_in     = b;
            uio_in[0] = 1'b1;
            uio_in[1] = is_cfg;
            @(posedge clk);
            uio_in[0] = 1'b0;
            uio_in[1] = 1'b0;
            bytes_in++;
        end
    endtask

    logic [OutBytes*8-1:0] rx_word;

    // Collect one result frame: OutBytes bytes while o_valid is high.
    task automatic recv_frame;
        int k;
        begin
            rx_word = '0;
            k = 0;
            while (k < OutBytes) begin
                @(posedge clk);
                if (o_valid) begin
                    rx_word = {rx_word[OutBytes*8-9:0], uo_out};
                    bytes_out++;
                    k++;
                end
            end
        end
    endtask

    logic signed [MIX_BITS-1:0] got_i, got_q;

    initial begin
        $readmemh({VEC_DIR, "/stim_i.hex"}, stim_i);
        $readmemh({VEC_DIR, "/stim_q.hex"}, stim_q);
        $readmemh({VEC_DIR, "/mix_i.hex"},  mix_i_exp);
        $readmemh({VEC_DIR, "/mix_q.hex"},  mix_q_exp);

        ui_in = '0; uio_in = '0; rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Config: PHASE_INC, big-endian.
        for (int b = CfgBytes - 1; b >= 0; b--)
            send_byte(PHASE_INC[b*8 +: 8], 1'b1);

        t_start = clocks;

        // Send and receive as independent processes, the way a real host with
        // separate TX and RX paths would drive this. Driving them in sequence
        // instead would hide the input/output overlap the wrapper allows and
        // understate the achievable rate by about five clocks per sample.
        fork
            begin : producer
                for (int i = 0; i < N_TEST; i++) begin
                    // Sample frame: xi then xq, each big-endian.
                    for (int b = (DATA_BITS/8) - 1; b >= 0; b--)
                        send_byte(stim_i[i][b*8 +: 8], 1'b0);
                    for (int b = (DATA_BITS/8) - 1; b >= 0; b--)
                        send_byte(stim_q[i][b*8 +: 8], 1'b0);
                end
            end

            begin : consumer
                for (int i = 0; i < N_TEST; i++) begin
                    recv_frame();
                    got_i = rx_word[OutBits-1 -: MIX_BITS];
                    got_q = rx_word[MIX_BITS-1 : 0];

                    if (got_i !== mix_i_exp[i] || got_q !== mix_q_exp[i]) begin
                        n_fail++;
                        if (n_fail <= 5) begin
                            $display("FAIL sample %0d: xi=%0d xq=%0d",
                                     i, stim_i[i], stim_q[i]);
                            $display("  expected mix_i=%0d mix_q=%0d",
                                     mix_i_exp[i], mix_q_exp[i]);
                            $display("  got      mix_i=%0d mix_q=%0d",
                                     got_i, got_q);
                        end
                    end
                end
            end
        join

        t_end = clocks;

        if (o_ovf) begin
            n_fail++;
            $display("FAIL: overflow flag latched -- a result went unread");
        end

        $display("");
        $display("pin usage: %0d in, %0d out, %0d bidir (uio_oe=%b)",
                 8, 8, 8, uio_oe);
        $display("per sample: %0d bytes in, %0d bytes out, %0.1f clocks",
                 SampBytes, OutBytes, real'(t_end - t_start) / real'(N_TEST));
        if (n_fail == 0)
            $display("ALL %0d SERIALISED SAMPLES PASSED", N_TEST);
        else
            $display("%0d of %0d SERIALISED SAMPLES FAILED", n_fail, N_TEST);

        $finish;
    end

endmodule
