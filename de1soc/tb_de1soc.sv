// Self-checking testbench for the DE1-SoC board top level.
//
// The board design is itself a self test, so this checks the checker: that
// it plays the whole stimulus, receives every expected output, reports zero
// mismatches, and lights the pass LED. A board wrapper is exactly the kind
// of code that is easy to get subtly wrong (an off-by-one on the last
// output, a comparison against the wrong index, a done flag that never
// sets) and hard to debug once it is only observable through ten LEDs.
//
// It also checks the negative case: with the expected-output ROM
// deliberately mismatched, the design must report failure rather than pass.
// Without that, a wrapper that compared nothing at all would look identical
// to one that worked.
//
// Run via de1soc/run_sim_de1soc.sh.

`timescale 1ns/1ps
`include "selftest_rom.svh"

module tb_de1soc;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW = '0;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    logic        ADC_DOUT = 1'b0;

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
        .ADC_DOUT   (ADC_DOUT)
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


// Same design, but fed a corrupted expectation, to prove the pass LED is
// actually a function of the comparison and not stuck on.
module tb_de1soc_negative;

    logic        CLOCK_50 = 0;
    logic [3:0]  KEY;
    logic [9:0]  SW = '0;
    wire  [9:0]  LEDR;
    wire  [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire         ADC_CONVST, ADC_SCLK, ADC_DIN;
    logic        ADC_DOUT = 1'b0;

    // Same design, built at a different LO than the ROM was generated for.
    // Every output is then legitimately different from the expectation, so
    // a working comparison must report failure. Overriding the parameter is
    // preferable to forcing internals: it corrupts the design's *input*
    // rather than reaching inside it, so what is being tested stays the
    // real comparison path.
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
        .ADC_DOUT   (ADC_DOUT)
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
