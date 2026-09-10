// Self-checking testbench for iq_avalon_fifo: register map, FIFO ordering,
// drop accounting, flush, and a simultaneous push/pop.
//
// DEPTH is 16, so overflow is reachable in a few hundred clocks.
// Run via de1soc/run_sim_egress.sh.

`timescale 1ns/1ps

module tb_iq_avalon_fifo;

    localparam int Depth      = 16;
    localparam int DataBits   = 16;
    localparam int PhaseBits  = 24;

    localparam logic [2:0] RegId    = 3'd0, RegCtrl   = 3'd1, RegPhase = 3'd2,
                           RegLevel = 3'd3, RegStatus = 3'd4, RegData  = 3'd5;

    localparam logic [31:0] IdCode = 32'h5344_5202;

    logic clk = 0;
    logic rst_n = 0;

    logic [2:0]  avs_address   = '0;
    logic        avs_read      = 0;
    logic [31:0] avs_readdata;
    logic        avs_readdatavalid;
    logic        avs_waitrequest;
    logic        avs_write     = 0;
    logic [31:0] avs_writedata = '0;

    logic                       iq_valid = 0;
    logic signed [DataBits-1:0] iq_i = '0, iq_q = '0;

    logic                  tap_full;
    logic                  enable;
    logic [PhaseBits-1:0]  phase_inc;
    logic [15:0]           level, drops;
    logic                  overflow;

    int n_fail = 0;
    int rdv_bad = 0;

    always #10 clk <= ~clk;   // 50 MHz

    iq_avalon_fifo #(
        .DEPTH      (Depth),
        .DATA_BITS  (DataBits),
        .PHASE_BITS (PhaseBits)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .avs_address   (avs_address),
        .avs_read      (avs_read),
        .avs_readdata  (avs_readdata),
        .avs_readdatavalid (avs_readdatavalid),
        .avs_waitrequest   (avs_waitrequest),
        .avs_write     (avs_write),
        .avs_writedata (avs_writedata),
        .iq_valid      (iq_valid),
        .iq_i          (iq_i),
        .iq_q          (iq_q),
        .tap_full      (tap_full),
        .enable        (enable),
        .phase_inc     (phase_inc),
        .level         (level),
        .drops         (drops),
        .overflow      (overflow)
    );

    // Read latency and waitrequest, checked every clock rather than only
    // where the BFM samples. checking gates on reset, since rst_n is
    // asynchronous in the DUT.
    bit checking = 0;

    logic read_d = 0;
    always_ff @(posedge clk) read_d <= avs_read;

    always_ff @(posedge clk) begin
        if (checking && (avs_readdatavalid !== read_d || avs_waitrequest !== 1'b0))
            rdv_bad <= rdv_bad + 1;
    end

    `include "avalon_bfm.svh"

    task automatic push(input logic signed [DataBits-1:0] vi,
                        input logic signed [DataBits-1:0] vq);
        @(negedge clk);
        iq_i     = vi;
        iq_q     = vq;
        iq_valid = 1'b1;
        @(negedge clk);
        iq_valid = 1'b0;
    endtask

    task automatic expect_reg(input logic [2:0] a, input logic [31:0] exp,
                              input string what);
        logic [31:0] got;
        av_read(a, got);
        if (got !== exp) begin
            n_fail = n_fail + 1;
            $display("FAIL %s: expected %08h, got %08h", what, exp, got);
        end

        // The board reads these ports, not the register file.
        if (a == RegLevel && got !== 32'(level)) begin
            n_fail = n_fail + 1;
            $display("FAIL level port %04h against LEVEL %08h", level, got);
        end
        if (a == RegStatus && got !== {15'd0, overflow, drops}) begin
            n_fail = n_fail + 1;
            $display("FAIL status ports (drops=%04h overflow=%b) against STATUS %08h",
                     drops, overflow, got);
        end
    endtask

    logic [31:0] d;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        checking = 1;

        // -- identity and control registers --------------------------------
        expect_reg(RegId, IdCode, "ID");

        // Full-rate tap, host not yet streaming.
        expect_reg(RegCtrl, 32'h0000_0001, "CTRL out of reset");

        av_write(RegPhase, 32'h0012_3456);
        expect_reg(RegPhase, 32'h0012_3456, "PHASE_INC readback");
        if (phase_inc !== 24'h123456) begin
            n_fail = n_fail + 1;
            $display("FAIL phase_inc port: got %06h", phase_inc);
        end

        // -- disabled: nothing is captured ---------------------------------
        push(16'sd100, -16'sd100);
        push(16'sd101, -16'sd101);
        expect_reg(RegLevel, 32'd0, "LEVEL while disabled");

        // -- enable, fill, drain in order ----------------------------------
        av_write(RegCtrl, 32'h0000_0003);
        if (!enable || !tap_full) begin
            n_fail = n_fail + 1;
            $display("FAIL CTRL did not take: enable=%b tap_full=%b", enable, tap_full);
        end

        for (int i = 0; i < 8; i++)
            push(DataBits'(i + 1), -DataBits'(i + 1));

        expect_reg(RegLevel, 32'd8, "LEVEL after 8 pushes");

        for (int i = 0; i < 8; i++) begin
            av_read(RegData, d);
            if (d !== {DataBits'(i + 1), -DataBits'(i + 1)}) begin
                n_fail = n_fail + 1;
                $display("FAIL DATA[%0d]: expected %08h, got %08h",
                         i, {DataBits'(i + 1), -DataBits'(i + 1)}, d);
            end
        end

        expect_reg(RegLevel, 32'd0, "LEVEL after draining");

        // Reading past the end yields zero and does not move the pointer.
        expect_reg(RegData, 32'd0, "DATA while empty");
        expect_reg(RegLevel, 32'd0, "LEVEL after an empty read");

        // -- overflow -------------------------------------------------------
        for (int i = 0; i < Depth + 4; i++)
            push(DataBits'(i), DataBits'(i));

        expect_reg(RegLevel, 32'(Depth), "LEVEL when full");
        expect_reg(RegStatus, {15'd0, 1'b1, 16'd4}, "STATUS after 4 drops");

        // The four dropped pairs are the newest, so the front is still 0.
        av_read(RegData, d);
        if (d !== {DataBits'(0), DataBits'(0)}) begin
            n_fail = n_fail + 1;
            $display("FAIL oldest entry survived overflow: got %08h", d);
        end

        // -- flush -----------------------------------------------------------
        av_write(RegCtrl, 32'h0000_0007);
        expect_reg(RegLevel, 32'd0, "LEVEL after flush");
        expect_reg(RegStatus, 32'd0, "STATUS after flush");
        if (!enable) begin
            n_fail = n_fail + 1;
            $display("FAIL flush cleared enable");
        end

        // -- push and pop on the same clock ----------------------------------
        push(16'sd7, 16'sd7);
        for (int i = 0; i < 4; i++) begin
            fork
                push(DataBits'(20 + i), DataBits'(20 + i));
                av_read(RegData, d);
            join
        end
        expect_reg(RegLevel, 32'd1, "LEVEL after 4 simultaneous transfers");
        expect_reg(RegStatus, 32'd0, "no drops during simultaneous transfers");

        if (rdv_bad != 0) begin
            n_fail = n_fail + 1;
            $display("FAIL: readdatavalid or waitrequest misbehaved on %0d clocks",
                     rdv_bad);
        end

        if (n_fail != 0)
            $fatal(1, "tb_iq_avalon_fifo: %0d checks failed", n_fail);

        $display("ALL IQ AVALON FIFO CHECKS PASSED");
        $finish;
    end

endmodule
