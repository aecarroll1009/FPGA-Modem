// Self-checking testbench for uart_tx: decodes the line with an independent
// mid-bit receiver and checks the idle level, start/stop framing, LSB-first
// bit order, and in_ready's timing.
//
// Run via de1soc/run_sim_uart.sh.

`timescale 1ns/1ps

module tb_uart_tx;

    // Short for a fast run, wide enough that mid-bit sampling is real.
    localparam int ClksPerBit = 8;
    localparam int NBytes     = 12;

    logic       clk = 0;
    logic       rst_n;
    logic       in_valid;
    logic [7:0] in_byte;
    logic       in_ready;
    logic       tx;

    uart_tx #(.CLKS_PER_BIT(ClksPerBit)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_byte  (in_byte),
        .in_ready (in_ready),
        .tx       (tx)
    );

    always #10 clk <= ~clk;   // 50 MHz

    logic [7:0] sent [0:NBytes-1];
    logic [7:0] rcvd [0:NBytes-1];
    int n_rcvd = 0;
    int n_fail = 0;

    // -- receiver: independent of the DUT's own timing ---------------------
    // Waits for the start bit, steps to its middle, samples every
    // ClksPerBit clocks. A mistimed DUT lands a sample in the wrong cell.
    task automatic uart_receive(output logic [7:0] b, output bit ok);
        int i;
        logic stop_bit;
        begin
            ok = 1'b1;
            @(negedge tx);                              // start bit
            repeat (ClksPerBit / 2) @(posedge clk);     // middle of start
            if (tx !== 1'b0) ok = 1'b0;
            for (i = 0; i < 8; i++) begin
                repeat (ClksPerBit) @(posedge clk);
                b[i] = tx;                              // LSB first
            end
            repeat (ClksPerBit) @(posedge clk);
            stop_bit = tx;
            if (stop_bit !== 1'b1) ok = 1'b0;
        end
    endtask

    initial begin
        logic [7:0] b;
        bit ok;
        forever begin
            uart_receive(b, ok);
            if (!ok) begin
                n_fail++;
                $display("FAIL: framing error on byte %0d", n_rcvd);
            end
            if (n_rcvd < NBytes) rcvd[n_rcvd] = b;
            n_rcvd++;
        end
    end

    // -- driver ------------------------------------------------------------
    int idle_high_fail = 0;
    int i;

    initial begin
        // 00/FF for the all-zero and all-one patterns, 01/80 for bit order.
        sent[0] = 8'h00; sent[1] = 8'hFF; sent[2] = 8'h01; sent[3] = 8'h80;
        sent[4] = 8'h53; sent[5] = 8'h44; sent[6] = 8'h52; sent[7] = 8'h01;
        sent[8] = 8'hA5; sent[9] = 8'h5A; sent[10] = 8'h0F; sent[11] = 8'hF0;

        in_valid = 1'b0;
        in_byte  = 8'h00;
        rst_n    = 1'b0;
        repeat (4) @(posedge clk);

        if (tx !== 1'b1) begin
            idle_high_fail++;
            $display("FAIL: tx is not high while in reset");
        end

        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        if (tx !== 1'b1) begin
            idle_high_fail++;
            $display("FAIL: tx is not high when idle");
        end
        if (!in_ready) begin
            n_fail++;
            $display("FAIL: in_ready is low while idle");
        end

        for (i = 0; i < NBytes; i++) begin
            @(posedge clk);
            in_byte   = sent[i];
            in_valid  = 1'b1;
            @(posedge clk);
            in_valid  = 1'b0;
            // in_ready falls for the character, then returns.
            @(posedge clk);
            if (in_ready) begin
                n_fail++;
                $display("FAIL: in_ready still high one clock into byte %0d", i);
            end
            wait (in_ready);
        end

        // Let the last character clear the wire.
        repeat (ClksPerBit * 12) @(posedge clk);

        if (n_rcvd < NBytes) begin
            n_fail++;
            $display("FAIL: received %0d bytes, expected %0d", n_rcvd, NBytes);
        end else begin
            for (i = 0; i < NBytes; i++) begin
                if (rcvd[i] !== sent[i]) begin
                    n_fail++;
                    $display("FAIL: byte %0d: sent %02h, received %02h",
                             i, sent[i], rcvd[i]);
                end
            end
        end

        n_fail += idle_high_fail;

        if (n_fail == 0)
            $display("UART TX PASSED (%0d bytes, %0d clocks per bit)",
                     NBytes, ClksPerBit);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_uart_tx: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule
