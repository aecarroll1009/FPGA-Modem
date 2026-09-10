// Self-checking testbenches for de1soc_core.
// tb_de1soc plays the self-test stimulus and checks the reported
// pass/fail/counts; tb_de1soc_negative feeds a mismatched expectation and
// checks failure is reported; tb_de1soc_live drives the ADC pins and drains
// the FIFO over Avalon the way the HPS daemon does.
//
// Run via de1soc/run_sim_de1soc.sh.

`timescale 1ns/1ps
`include "selftest_rom.svh"
`include "adc_vectors.svh"

module tb_de1soc;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    logic        ADC_DOUT = 1'b0;

    logic [2:0]  avs_address   = '0;
    logic        avs_read      = 1'b0;
    wire  [31:0] avs_readdata;
    wire         avs_readdatavalid;
    wire         avs_waitrequest;
    logic        avs_write     = 1'b0;
    logic [31:0] avs_writedata = '0;

    // The BFM drives a net named clk.
    wire clk = CLOCK_50;

    de1soc_core dut (
        .CLOCK_50   (CLOCK_50),
        .KEY        (KEY),
        .SW         (SW),
        .LEDR       (LEDR),
        .HEX0       (HEX0),
        .HEX1       (HEX1),
        .HEX2       (HEX2),
        .HEX3       (HEX3),
        .HEX4       (HEX4),
        .HEX5       (HEX5),
        .ADC_CONVST (ADC_CONVST),
        .ADC_SCLK   (ADC_SCLK),
        .ADC_DIN    (ADC_DIN),
        .ADC_DOUT   (ADC_DOUT),
        .avs_address   (avs_address),
        .avs_read      (avs_read),
        .avs_readdata  (avs_readdata),
        .avs_readdatavalid (avs_readdatavalid),
        .avs_waitrequest   (avs_waitrequest),
        .avs_write     (avs_write),
        .avs_writedata (avs_writedata)
    );

    always #10 CLOCK_50 <= ~CLOCK_50;   // 50 MHz

    wire done = LEDR[0];
    wire pass = LEDR[1];
    wire fail = LEDR[2];
    wire ovf  = LEDR[3];

    int n_fail = 0;
    int cycles;

    `include "avalon_bfm.svh"

    // The host's view of the same self-test: the words the HPS reads must
    // match the ROM the on-chip comparator uses.
    localparam int NOut = `SELFTEST_N_OUT;
    localparam logic [2:0] RegCtrl = 3'd1, RegLevel = 3'd3, RegData = 3'd5;

    logic [31:0] rx [0:NOut-1];
    int n_rx = 0;

    initial begin
        logic [31:0] lvl, w;
        @(posedge KEY[0]);
        av_write(RegCtrl, 32'h0000_0002);      // streaming on
        while (n_rx < NOut) begin
            av_read(RegLevel, lvl);
            while (lvl != 0 && n_rx < NOut) begin
                av_read(RegData, w);
                rx[n_rx] = w;
                n_rx++;
                lvl--;
            end
        end
    end

    initial begin
        KEY = 4'b1111;
        SW  = 10'b0;                    // ROM self-test
        KEY[0] = 1'b0;                  // held reset (buttons read 0 pressed)
        repeat (4) @(posedge CLOCK_50);
        KEY[0] = 1'b1;

        // ~19 clocks per sample through the mixer, plus the FIR's own work.
        // Allow generous margin; the loop exits as soon as done rises.
        cycles = 0;
        while ((!done || n_rx < NOut) && cycles < 200_000) begin
            @(posedge CLOCK_50);
            cycles++;
        end

        if (!done) begin
            n_fail++;
            $display("FAIL: never finished -- %0d outputs received in %0d clocks",
                     dut.n_recv, cycles);
        end else begin
            $display("finished in %0d clocks (%0d stimulus samples, %0d outputs)",
                     cycles, `SELFTEST_N_STIM, `SELFTEST_N_OUT);
            if (dut.n_recv !== 8'(`SELFTEST_N_OUT)) begin
                n_fail++;
                $display("FAIL: received %0d outputs, expected %0d",
                         dut.n_recv, `SELFTEST_N_OUT);
            end
            if (dut.n_bad !== 8'd0) begin
                n_fail++;
                $display("FAIL: %0d mismatches against the reference ROM", dut.n_bad);
            end
            if (!pass || fail) begin
                n_fail++;
                $display("FAIL: LEDs report pass=%0b fail=%0b", pass, fail);
            end
            if (ovf) begin
                n_fail++;
                $display("FAIL: out_overflow latched");
            end
            // The converter runs unconsumed here; the flag must stay dark.
            if (LEDR[5]) begin
                n_fail++;
                $display("FAIL: ADC overrun latched during the ROM self-test");
            end
            if (LEDR[4]) begin
                n_fail++;
                $display("FAIL: egress overflow latched during the ROM self-test");
            end
            if (LEDR[6]) begin
                n_fail++;
                $display("FAIL: live-mode LED lit with SW[0] low");
            end

            if (n_rx < NOut) begin
                n_fail++;
                $display("FAIL: only %0d of %0d words reached the HPS bus", n_rx, NOut);
            end else begin
                for (int s = 0; s < NOut; s++) begin
                    if (`SELFTEST_OUT_BITS'(rx[s][31:16]) !== SELFTEST_OUT_I[s] ||
                        `SELFTEST_OUT_BITS'(rx[s][15:0])  !== SELFTEST_OUT_Q[s]) begin
                        n_fail++;
                        $display("FAIL: word %0d read %08h, ROM says (%0d,%0d)",
                                 s, rx[s], SELFTEST_OUT_I[s], SELFTEST_OUT_Q[s]);
                    end
                end
            end
        end

        if (n_fail == 0)
            $display("DE1_SoC SELF TEST PASSED (pass LED lit, %0d/%0d outputs, 0 mismatches)",
                     dut.n_recv, `SELFTEST_N_OUT);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_de1soc: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule


// Fed a deliberately mismatched expectation; the DUT must report failure.
module tb_de1soc_negative;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    logic        ADC_DOUT = 1'b0;

    logic [2:0]  avs_address   = '0;
    logic        avs_read      = 1'b0;
    wire  [31:0] avs_readdata;
    wire         avs_readdatavalid;
    wire         avs_waitrequest;
    logic        avs_write     = 1'b0;
    logic [31:0] avs_writedata = '0;

    // The BFM drives a net named clk.
    wire clk = CLOCK_50;

    // Overrides PHASE_INC so every output legitimately mismatches the ROM's
    // expectation -- corrupts the design's input rather than forcing internals.
    de1soc_core #(.PHASE_INC(`SELFTEST_PHASE_INC ^ 24'h000100)) dut (
        .CLOCK_50   (CLOCK_50),
        .KEY        (KEY),
        .SW         (SW),
        .LEDR       (LEDR),
        .HEX0       (HEX0), .HEX1 (HEX1), .HEX2 (HEX2),
        .HEX3       (HEX3), .HEX4 (HEX4), .HEX5 (HEX5),
        .ADC_CONVST (ADC_CONVST),
        .ADC_SCLK   (ADC_SCLK),
        .ADC_DIN    (ADC_DIN),
        .ADC_DOUT   (ADC_DOUT),
        .avs_address   (avs_address),
        .avs_read      (avs_read),
        .avs_readdata  (avs_readdata),
        .avs_readdatavalid (avs_readdatavalid),
        .avs_waitrequest   (avs_waitrequest),
        .avs_write     (avs_write),
        .avs_writedata (avs_writedata)
    );

    always #10 CLOCK_50 <= ~CLOCK_50;

    int cycles;

    `include "avalon_bfm.svh"

    // Streams and discards; the corrupted run uses the same egress path.
    initial begin
        logic [31:0] lvl, w;
        @(posedge KEY[0]);
        av_write(3'd1, 32'h0000_0002);
        forever begin
            av_read(3'd3, lvl);
            while (lvl != 0) begin
                av_read(3'd5, w);
                lvl--;
            end
        end
    end

    initial begin
        KEY = 4'b1111;
        SW  = 10'b0;
        KEY[0] = 1'b0;
        repeat (4) @(posedge CLOCK_50);
        KEY[0] = 1'b1;

        cycles = 0;
        while (!LEDR[0] && cycles < 200_000) begin
            @(posedge CLOCK_50);
            cycles++;
        end

        if (LEDR[0] && LEDR[2] && !LEDR[1] && dut.n_bad != 8'd0)
            $display("NEGATIVE CHECK PASSED (%0d mismatch reported, pass LED dark)",
                     dut.n_bad);
        else begin
            $display("NEGATIVE CHECK FAILED: done=%0b pass=%0b fail=%0b n_bad=%0d -- a corrupted expectation was not detected",
                     LEDR[0], LEDR[1], LEDR[2], dut.n_bad);
            $fatal(1, "tb_de1soc_negative: corrupted expectation was not detected");
        end
        $finish;
    end

endmodule


// Live-ADC mode, end to end: an LTC2308 model feeds a known tone into the
// converter pins and an Avalon master drains the FIFO the way the HPS
// daemon does, checking every word against the reference model. The only
// test covering the whole board path as one piece.
module tb_de1soc_live;

    localparam int NOut    = `ADC_N_OUT;
    localparam int NCodes  = `ADC_N_CODES;
    localparam int OutBits = `SELFTEST_OUT_BITS;

    localparam logic [2:0] RegCtrl   = 3'd1, RegLevel = 3'd3,
                           RegStatus = 3'd4, RegData  = 3'd5;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    wire         ADC_DOUT;

    logic [2:0]  avs_address   = '0;
    logic        avs_read      = 1'b0;
    wire  [31:0] avs_readdata;
    wire         avs_readdatavalid;
    wire         avs_waitrequest;
    logic        avs_write     = 1'b0;
    logic [31:0] avs_writedata = '0;

    // The BFM drives a net named clk.
    wire clk = CLOCK_50;

    de1soc_core dut (
        .CLOCK_50      (CLOCK_50),
        .KEY           (KEY),
        .SW            (SW),
        .LEDR          (LEDR),
        .HEX0          (HEX0), .HEX1 (HEX1), .HEX2 (HEX2),
        .HEX3          (HEX3), .HEX4 (HEX4), .HEX5 (HEX5),
        .ADC_CONVST    (ADC_CONVST),
        .ADC_SCLK      (ADC_SCLK),
        .ADC_DIN       (ADC_DIN),
        .ADC_DOUT      (ADC_DOUT),
        .avs_address   (avs_address),
        .avs_read      (avs_read),
        .avs_readdata  (avs_readdata),
        .avs_readdatavalid (avs_readdatavalid),
        .avs_waitrequest   (avs_waitrequest),
        .avs_write     (avs_write),
        .avs_writedata (avs_writedata)
    );

    always #10 CLOCK_50 <= ~CLOCK_50;   // 50 MHz

    `include "avalon_bfm.svh"

    // -- the converter -----------------------------------------------------
    wire [15:0] conv_count;
    logic [11:0] next_code;
    int ci;

    // ltc2308_ctrl discards its first conversion, so conversions 0 and 1
    // both serve ADC_CODES[0] and the delivered sequence is in order.
    always_comb begin
        ci = (conv_count == 16'd0) ? 0 : int'(conv_count) - 1;
        if (ci > NCodes - 1) ci = NCodes - 1;
        next_code = ADC_CODES[ci];
    end

    ltc2308_model u_adc_model (
        .clk        (CLOCK_50),
        .rst_n      (KEY[0]),
        .adc_convst (ADC_CONVST),
        .adc_sclk   (ADC_SCLK),
        .next_code  (next_code),
        .adc_dout   (ADC_DOUT),
        .conv_count (conv_count)
    );

    // -- the reader ---------------------------------------------------------
    // Poll LEVEL, then pop that many words: what hps/iq_streamd.c does.
    logic [31:0] rx [0:NOut-1];
    int n_rx = 0;
    int n_fail = 0;

    initial begin
        logic [31:0] lvl, w;
        @(posedge KEY[0]);
        // Decimated tap, streaming on -- the vectors are FIR outputs.
        av_write(RegCtrl, 32'h0000_0002);
        while (n_rx < NOut) begin
            av_read(RegLevel, lvl);
            while (lvl != 0 && n_rx < NOut) begin
                av_read(RegData, w);
                rx[n_rx] = w;
                n_rx++;
                lvl--;
            end
        end
    end

    // -- run and check ------------------------------------------------------
    int cycles, s;
    logic [31:0] status;
    logic signed [OutBits-1:0] dec_i, dec_q;

    initial begin
        KEY = 4'b1111;
        SW  = 10'b0;
        SW[0] = 1'b1;            // live ADC mode
        KEY[0] = 1'b0;
        repeat (4) @(posedge CLOCK_50);
        KEY[0] = 1'b1;

        cycles = 0;
        while (n_rx < NOut && cycles < 400_000) begin
            @(posedge CLOCK_50);
            cycles++;
        end

        if (n_rx < NOut) begin
            n_fail++;
            $display("FAIL: drained %0d words in %0d clocks, expected %0d",
                     n_rx, cycles, NOut);
        end else begin
            for (s = 0; s < NOut; s++) begin
                dec_i = OutBits'(rx[s][31:16]);
                dec_q = OutBits'(rx[s][15:0]);
                if (dec_i !== ADC_OUT_I[s] || dec_q !== ADC_OUT_Q[s]) begin
                    n_fail++;
                    $display("FAIL: output %0d read (%0d,%0d), model says (%0d,%0d)",
                             s, dec_i, dec_q, ADC_OUT_I[s], ADC_OUT_Q[s]);
                end
            end
        end

        repeat (4) @(posedge CLOCK_50);
        av_read(RegStatus, status);
        if (status !== 32'd0) begin
            n_fail++;
            $display("FAIL: STATUS reports %08h, expected a clean drain", status);
        end

        if (!LEDR[6]) begin
            n_fail++;
            $display("FAIL: live-mode LED is dark with SW[0] high");
        end
        if (!LEDR[7]) begin
            n_fail++;
            $display("FAIL: streaming LED is dark after CTRL enabled it");
        end
        if (LEDR[3]) begin n_fail++; $display("FAIL: rx_top out_overflow latched"); end
        if (LEDR[4]) begin n_fail++; $display("FAIL: egress overflow latched"); end
        if (LEDR[5]) begin n_fail++; $display("FAIL: ADC overrun latched"); end

        if (n_fail == 0)
            $display("DE1_SoC LIVE ADC PASSED (%0d words drained over Avalon in %0d clocks, bit-exact vs the reference model)",
                     NOut, cycles);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_de1soc_live: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule
