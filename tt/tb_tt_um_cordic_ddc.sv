// Self-checking testbench for the TinyTapeout wrapper: drives the byte-serial
// protocol, reassembles result bytes, and checks them against the same
// mix_i/mix_q vectors the parallel testbench uses.
// The direction pin toggles every sample and is latched only on the clock
// the last sample byte lands, so RX and TX rotations interleave through the
// one rotator.
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
    logic signed [MIX_BITS-1:0]  up_i_exp  [0:N_STIM-1];
    logic signed [MIX_BITS-1:0]  up_q_exp  [0:N_STIM-1];

    // Sample i is down-converted when even. Both processes derive the
    // direction from the loop index alone, so they cannot disagree.
    function automatic logic want_down(input int i);
        want_down = (i % 2 == 0);
    endfunction

    int n_fail = 0;
    int bytes_in = 0, bytes_out = 0;

    // Runs free from reset onward; the sample loop below brackets its own
    // measurement window to exclude reset and config time from the average.
    int clocks = 0;
    always @(posedge clk) clocks <= clocks + 1;
    int t_start, t_end;

    // Send one byte, holding it until the DUT can take it. `dir` is driven
    // only for the clock the byte lands, then inverted.
    task automatic send_byte(input logic [7:0] b, input logic is_cfg, input logic dir);
        begin
            if (!is_cfg) while (!i_ready) @(posedge clk);
            ui_in     = b;
            uio_in[0] = 1'b1;
            uio_in[1] = is_cfg;
            uio_in[5] = dir;
            @(posedge clk);
            uio_in[0] = 1'b0;
            uio_in[1] = 1'b0;
            uio_in[5] = !dir;
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
        $readmemh({VEC_DIR, "/mix_i.hex"},    mix_i_exp);
        $readmemh({VEC_DIR, "/mix_q.hex"},    mix_q_exp);
        $readmemh({VEC_DIR, "/mix_up_i.hex"}, up_i_exp);
        $readmemh({VEC_DIR, "/mix_up_q.hex"}, up_q_exp);

        ui_in = '0; uio_in = '0; rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Config: PHASE_INC, big-endian. Config bytes carry no direction.
        for (int b = CfgBytes - 1; b >= 0; b--)
            send_byte(PHASE_INC[b*8 +: 8], 1'b1, 1'b1);

        t_start = clocks;

        // Send and receive concurrently, as separate TX/RX paths would, so
        // the measured rate reflects the input/output overlap the wrapper allows.
        fork
            begin : producer
                for (int i = 0; i < N_TEST; i++) begin
                    // Sample frame: xi then xq, each big-endian.
                    for (int b = (DATA_BITS/8) - 1; b >= 0; b--)
                        send_byte(stim_i[i][b*8 +: 8], 1'b0, want_down(i));
                    for (int b = (DATA_BITS/8) - 1; b >= 0; b--)
                        send_byte(stim_q[i][b*8 +: 8], 1'b0, want_down(i));
                end
            end

            begin : consumer
                logic signed [MIX_BITS-1:0] exp_i, exp_q;
                for (int i = 0; i < N_TEST; i++) begin
                    recv_frame();
                    got_i = rx_word[OutBits-1 -: MIX_BITS];
                    got_q = rx_word[MIX_BITS-1 : 0];

                    exp_i = want_down(i) ? mix_i_exp[i] : up_i_exp[i];
                    exp_q = want_down(i) ? mix_q_exp[i] : up_q_exp[i];

                    if (got_i !== exp_i || got_q !== exp_q) begin
                        n_fail++;
                        if (n_fail <= 5) begin
                            $display("FAIL sample %0d (%s): xi=%0d xq=%0d",
                                     i, want_down(i) ? "down" : "up",
                                     stim_i[i], stim_q[i]);
                            $display("  expected mix_i=%0d mix_q=%0d", exp_i, exp_q);
                            $display("  got      mix_i=%0d mix_q=%0d", got_i, got_q);
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
        $display("direction: alternating per sample (%0d down, %0d up)",
                 (N_TEST + 1) / 2, N_TEST / 2);
        if (n_fail == 0)
            $display("ALL %0d SERIALISED SAMPLES PASSED", N_TEST);
        else begin
            $display("%0d of %0d SERIALISED SAMPLES FAILED", n_fail, N_TEST);
            $fatal(1, "tb_tt_um_cordic_ddc: %0d of %0d samples failed", n_fail, N_TEST);
        end

        $finish;
    end

endmodule
