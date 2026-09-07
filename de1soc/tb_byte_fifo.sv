// Self-checking testbench for byte_fifo: checks ordering, the empty and
// full flags at both boundaries, that a write to a full FIFO is refused,
// and that a same-clock read and write leave occupancy unchanged.
//
// Run via de1soc/run_sim_uart.sh.

`timescale 1ns/1ps

module tb_byte_fifo;

    localparam int Depth = 8;

    logic       clk = 0;
    logic       rst_n;
    logic       wr_en, rd_en;
    logic [7:0] wr_data, rd_data;
    logic       full, empty;

    byte_fifo #(.DEPTH(Depth)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (wr_en),
        .wr_data (wr_data),
        .full    (full),
        .rd_en   (rd_en),
        .rd_data (rd_data),
        .empty   (empty)
    );

    always #10 clk <= ~clk;

    int n_fail = 0;
    int i;

    task automatic push(input logic [7:0] b);
        begin
            @(posedge clk);
            wr_data  = b;
            wr_en    = 1'b1;
            @(posedge clk);
            wr_en  = 1'b0;
        end
    endtask

    task automatic pop(output logic [7:0] b);
        begin
            b = rd_data;      // combinational read, valid while !empty
            @(posedge clk);
            rd_en  = 1'b1;
            @(posedge clk);
            rd_en  = 1'b0;
        end
    endtask

    logic [7:0] got;

    initial begin
        wr_en = 0; rd_en = 0; wr_data = 0;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        if (!empty) begin n_fail++; $display("FAIL: not empty after reset"); end
        if (full)   begin n_fail++; $display("FAIL: full after reset"); end

        // Fill exactly to Depth and check the boundary flags.
        for (i = 0; i < Depth; i++) begin
            if (full) begin
                n_fail++;
                $display("FAIL: full asserted early, after %0d writes", i);
            end
            push(8'(i + 32));
        end
        if (!full) begin n_fail++; $display("FAIL: not full after %0d writes", Depth); end
        if (empty) begin n_fail++; $display("FAIL: empty while full"); end

        // A write to a full FIFO is refused.
        push(8'hEE);
        if (!full) begin n_fail++; $display("FAIL: full deasserted by a refused write"); end

        // Drain and check ordering; the refused byte must not appear.
        for (i = 0; i < Depth; i++) begin
            if (empty) begin
                n_fail++;
                $display("FAIL: empty asserted early, after %0d reads", i);
            end
            pop(got);
            if (got !== 8'(i + 32)) begin
                n_fail++;
                $display("FAIL: read %0d returned %02h, expected %02h",
                         i, got, 8'(i + 32));
            end
        end
        if (!empty) begin n_fail++; $display("FAIL: not empty after draining"); end

        // Same-clock read and write: occupancy holds, order preserved.
        push(8'hA1);
        push(8'hA2);
        @(posedge clk);
        wr_data  = 8'hA3;
        wr_en    = 1'b1;
        rd_en    = 1'b1;
        got      = rd_data;
        @(posedge clk);
        wr_en  = 1'b0;
        rd_en  = 1'b0;
        @(posedge clk);
        if (got !== 8'hA1) begin
            n_fail++;
            $display("FAIL: simultaneous access read %02h, expected A1", got);
        end
        pop(got);
        if (got !== 8'hA2) begin
            n_fail++;
            $display("FAIL: after simultaneous access read %02h, expected A2", got);
        end
        pop(got);
        if (got !== 8'hA3) begin
            n_fail++;
            $display("FAIL: after simultaneous access read %02h, expected A3", got);
        end
        if (!empty) begin n_fail++; $display("FAIL: not empty at end of test"); end

        if (n_fail == 0)
            $display("BYTE FIFO PASSED (depth %0d)", Depth);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_byte_fifo: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule
