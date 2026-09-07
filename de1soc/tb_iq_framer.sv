// Self-checking testbench for iq_framer: decodes the byte stream the way
// host/capture_iq.py does, checking frame boundaries, the sequence counter,
// big-endian IQ round-trip, and that backpressure only delays bytes.
//
// Run via de1soc/run_sim_uart.sh.

`timescale 1ns/1ps

module tb_iq_framer;

    localparam int DataBits = 16;
    // Small so several frames fit a short run; the board uses 64.
    localparam int SamplesPerFrame = 4;
    localparam int NFrames  = 3;
    localparam int NSamples = SamplesPerFrame * NFrames;
    localparam int NBytes   = NFrames * (6 + 4 * SamplesPerFrame);

    logic clk = 0, rst_n;
    logic in_valid;
    logic signed [DataBits-1:0] in_i, in_q;
    logic out_valid, out_ready;
    logic [7:0] out_byte;
    logic overflow;
    logic [15:0] frame_count;

    iq_framer #(
        .DATA_BITS         (DataBits),
        .SAMPLES_PER_FRAME (SamplesPerFrame)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_i      (in_i),
        .in_q      (in_q),
        .out_valid (out_valid),
        .out_byte  (out_byte),
        .out_ready (out_ready),
        .overflow  (overflow),
        .frame_count (frame_count)
    );

    always #10 clk <= ~clk;

    logic signed [DataBits-1:0] sent_i [0:NSamples-1];
    logic signed [DataBits-1:0] sent_q [0:NSamples-1];
    logic [7:0] stream [0:NBytes*2-1];
    int n_bytes = 0;
    int n_fail  = 0;

    // Collects every accepted byte. Gated on `collecting`, not rst_n, which
    // the DUT uses as an async reset.
    bit collecting = 0;

    always_ff @(posedge clk) begin
        if (collecting && out_valid && out_ready && n_bytes < NBytes*2) begin
            stream[n_bytes] <= out_byte;
            n_bytes         <= n_bytes + 1;
        end
    end

    int i, f, s, base;
    logic [15:0] seq;
    logic signed [DataBits-1:0] dec_i, dec_q;

    initial begin
        in_valid = 0; in_i = 0; in_q = 0; out_ready = 1;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        collecting = 1;

        for (i = 0; i < NSamples; i++) begin
            // Pins down byte order and sign extension.
            sent_i[i] = DataBits'(16'h1000 + 16'(i));
            sent_q[i] = -DataBits'(16'h0200 + 16'(i));
        end

        for (i = 0; i < NSamples; i++) begin
            @(posedge clk);
            in_i      = sent_i[i];
            in_q      = sent_q[i];
            in_valid  = 1'b1;
            @(posedge clk);
            in_valid  = 1'b0;

            // Stall the sink on alternate samples, forcing a mid-pair pause.
            if (i % 2 == 1) begin
                out_ready  = 1'b0;
                repeat (5) @(posedge clk);
                out_ready  = 1'b1;
            end

            // The board leaves ~1000 clocks between pairs; 40 covers 10 bytes.
            repeat (40) @(posedge clk);
        end

        repeat (20) @(posedge clk);

        if (overflow) begin
            n_fail++;
            $display("FAIL: overflow latched with the sink keeping up");
        end
        // Must track the counter that went out in the headers.
        if (frame_count !== 16'(NFrames)) begin
            n_fail++;
            $display("FAIL: frame_count is %0d after %0d complete frames",
                     frame_count, NFrames);
        end
        if (n_bytes !== NBytes) begin
            n_fail++;
            $display("FAIL: collected %0d bytes, expected %0d", n_bytes, NBytes);
        end else begin
            for (f = 0; f < NFrames; f++) begin
                base = f * (6 + 4 * SamplesPerFrame);
                if (stream[base]   !== 8'h53 || stream[base+1] !== 8'h44 ||
                    stream[base+2] !== 8'h52 || stream[base+3] !== 8'h01) begin
                    n_fail++;
                    $display("FAIL: frame %0d magic is %02h%02h%02h%02h", f,
                             stream[base], stream[base+1],
                             stream[base+2], stream[base+3]);
                end
                seq = {stream[base+4], stream[base+5]};
                if (seq !== 16'(f)) begin
                    n_fail++;
                    $display("FAIL: frame %0d sequence is %0d", f, seq);
                end
                for (s = 0; s < SamplesPerFrame; s++) begin
                    i     = f * SamplesPerFrame + s;
                    dec_i = DataBits'({stream[base+6+4*s],   stream[base+7+4*s]});
                    dec_q = DataBits'({stream[base+8+4*s],   stream[base+9+4*s]});
                    if (dec_i !== sent_i[i] || dec_q !== sent_q[i]) begin
                        n_fail++;
                        $display("FAIL: sample %0d decoded (%0d,%0d), sent (%0d,%0d)",
                                 i, dec_i, dec_q, sent_i[i], sent_q[i]);
                    end
                end
            end
        end

        if (n_fail == 0)
            $display("IQ FRAMER PASSED (%0d frames, %0d samples, %0d bytes)",
                     NFrames, NSamples, n_bytes);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_iq_framer: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule
