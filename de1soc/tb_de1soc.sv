// Self-checking testbenches for the DE1-SoC board top level.
// tb_de1soc plays the self-test stimulus and checks the reported
// pass/fail/counts; tb_de1soc_negative feeds a mismatched expectation and
// checks failure is reported; tb_de1soc_live drives the ADC pins and decodes
// UART_TX.
//
// Run via de1soc/run_sim_de1soc.sh.

`timescale 1ns/1ps
`include "selftest_rom.svh"
`include "adc_vectors.svh"

module tb_de1soc;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW = '0;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    logic        ADC_DOUT = 1'b0;
    wire         UART_TX;

    DE1_SoC dut (
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
        .UART_TX    (UART_TX)
    );

    always #10 CLOCK_50 <= ~CLOCK_50;   // 50 MHz

    wire done = LEDR[0];
    wire pass = LEDR[1];
    wire fail = LEDR[2];
    wire ovf  = LEDR[3];

    int n_fail = 0;
    int cycles;

    initial begin
        KEY = 4'b1111;
        KEY[0] = 1'b0;                  // held reset (buttons read 0 pressed)
        repeat (4) @(posedge CLOCK_50);
        KEY[0] = 1'b1;

        // ~19 clocks per sample through the mixer, plus the FIR's own work.
        // Allow generous margin; the loop exits as soon as done rises.
        cycles = 0;
        while (!done && cycles < 200_000) begin
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
    logic [9:0]  SW = '0;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    logic        ADC_DOUT = 1'b0;
    wire         UART_TX;

    // Overrides PHASE_INC so every output legitimately mismatches the ROM's
    // expectation -- corrupts the design's input rather than forcing internals.
    DE1_SoC #(.PHASE_INC(`SELFTEST_PHASE_INC ^ 24'h000100)) dut (
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
        .UART_TX    (UART_TX)
    );

    always #10 CLOCK_50 <= ~CLOCK_50;

    int cycles;

    initial begin
        KEY = 4'b1111;
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
// converter pins, and the framed IQ leaving UART_TX is decoded and checked
// against the reference model. The only test covering the whole board path
// as one piece.
module tb_de1soc_live;

    // Short bit period; the board uses 20.
    localparam int ClksPerBit      = 4;
    localparam int SamplesPerFrame = 64;
    localparam int NOut            = `ADC_N_OUT;
    localparam int NCodes          = `ADC_N_CODES;

    // 6 header bytes per frame, 4 per IQ pair.
    localparam int NFramesExpected = (NOut + SamplesPerFrame - 1) / SamplesPerFrame;
    localparam int NBytesExpected  = NFramesExpected * 6 + NOut * 4;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    wire         ADC_DOUT;
    wire         UART_TX;

    DE1_SoC #(
        .UART_CLKS_PER_BIT (ClksPerBit),
        .SAMPLES_PER_FRAME (SamplesPerFrame)
    ) dut (
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
        .UART_TX    (UART_TX)
    );

    always #10 CLOCK_50 <= ~CLOCK_50;   // 50 MHz

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

    // -- UART receiver -----------------------------------------------------
    logic [7:0] rx [0:NBytesExpected*2-1];
    int n_rx = 0;
    int n_fail = 0;

    task automatic uart_receive(output logic [7:0] b, output bit ok);
        int k;
        begin
            ok = 1'b1;
            @(negedge UART_TX);
            repeat (ClksPerBit / 2) @(posedge CLOCK_50);
            if (UART_TX !== 1'b0) ok = 1'b0;
            for (k = 0; k < 8; k++) begin
                repeat (ClksPerBit) @(posedge CLOCK_50);
                b[k] = UART_TX;
            end
            repeat (ClksPerBit) @(posedge CLOCK_50);
            if (UART_TX !== 1'b1) ok = 1'b0;
        end
    endtask

    initial begin
        logic [7:0] b;
        bit ok;
        forever begin
            uart_receive(b, ok);
            if (!ok && n_rx < NBytesExpected) begin
                n_fail++;
                $display("FAIL: UART framing error on byte %0d", n_rx);
            end
            if (n_rx < NBytesExpected*2) rx[n_rx] = b;
            n_rx++;
        end
    end

    // -- run and check -----------------------------------------------------
    int cycles, s, p, f;
    logic [15:0] seq;
    logic signed [`SELFTEST_OUT_BITS-1:0] dec_i, dec_q;

    initial begin
        KEY = 4'b1111;
        SW  = 10'b0;
        SW[0] = 1'b1;            // live ADC mode
        KEY[0] = 1'b0;
        repeat (4) @(posedge CLOCK_50);
        KEY[0] = 1'b1;

        cycles = 0;
        while (n_rx < NBytesExpected && cycles < 400_000) begin
            @(posedge CLOCK_50);
            cycles++;
        end

        if (n_rx < NBytesExpected) begin
            n_fail++;
            $display("FAIL: received %0d bytes in %0d clocks, expected %0d",
                     n_rx, cycles, NBytesExpected);
        end else begin
            p = 0;
            for (s = 0; s < NOut; s++) begin
                if (s % SamplesPerFrame == 0) begin
                    f = s / SamplesPerFrame;
                    if (rx[p]   !== 8'h53 || rx[p+1] !== 8'h44 ||
                        rx[p+2] !== 8'h52 || rx[p+3] !== 8'h01) begin
                        n_fail++;
                        $display("FAIL: frame %0d magic is %02h%02h%02h%02h at byte %0d",
                                 f, rx[p], rx[p+1], rx[p+2], rx[p+3], p);
                    end
                    seq = {rx[p+4], rx[p+5]};
                    if (seq !== 16'(f)) begin
                        n_fail++;
                        $display("FAIL: frame %0d sequence is %0d", f, seq);
                    end
                    p += 6;
                end
                dec_i = `SELFTEST_OUT_BITS'({rx[p],   rx[p+1]});
                dec_q = `SELFTEST_OUT_BITS'({rx[p+2], rx[p+3]});
                if (dec_i !== ADC_OUT_I[s] || dec_q !== ADC_OUT_Q[s]) begin
                    n_fail++;
                    $display("FAIL: output %0d decoded (%0d,%0d), model says (%0d,%0d)",
                             s, dec_i, dec_q, ADC_OUT_I[s], ADC_OUT_Q[s]);
                end
                p += 4;
            end
        end

        if (!LEDR[6]) begin
            n_fail++;
            $display("FAIL: live-mode LED is dark with SW[0] high");
        end
        if (LEDR[3]) begin n_fail++; $display("FAIL: rx_top out_overflow latched"); end
        if (LEDR[4]) begin n_fail++; $display("FAIL: egress overflow latched"); end
        if (LEDR[5]) begin n_fail++; $display("FAIL: ADC overrun latched"); end

        if (n_fail == 0)
            $display("DE1_SoC LIVE ADC PASSED (%0d outputs over %0d frames, %0d bytes, bit-exact vs the reference model)",
                     NOut, NFramesExpected, NBytesExpected);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_de1soc_live: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule
