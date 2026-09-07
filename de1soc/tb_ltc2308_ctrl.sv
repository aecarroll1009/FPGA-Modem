// Self-checking testbench for ltc2308_ctrl.
//
// There is no LTC2308 to test against, so this testbench *is* the ADC: an
// SPI slave model built directly from the datasheet's Figure 9 (short
// CONVST pulse) timing, driving SDO from a queue of programmed 12-bit codes
// and capturing whatever SDI word the master sends. That makes this a check
// of the *protocol*, not a comparison against silicon -- the real test is
// deferred until a board and the part are on hand.
//
// Checked, over many back-to-back samples:
//   - the very first sample is discarded (nothing was configured yet when
//     it converted -- see ltc2308_ctrl.sv's header)
//   - every sample from the second on decodes to exactly the code this
//     model queued for that conversion, in order
//   - the master's own DIN word is CH0/single-ended/unipolar/no-sleep on
//     every single transfer, not just the first
//   - sample_valid repeats every 125 clocks (400 kS/s at 50 MHz), not some
//     other period
//
// Run via de1soc/run_sim_ltc2308.sh.

`timescale 1ns/1ps

module tb_ltc2308_ctrl;

    localparam int Period = 125;
    localparam logic [5:0] ExpectedDin = 6'b100010;

    logic clk = 0, rst_n;
    logic adc_convst, adc_sclk, adc_din;
    logic adc_dout;
    logic sample_valid;
    logic [11:0] sample_code;

    ltc2308_ctrl dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .adc_convst   (adc_convst),
        .adc_sclk     (adc_sclk),
        .adc_din      (adc_din),
        .adc_dout     (adc_dout),
        .sample_valid (sample_valid),
        .sample_code  (sample_code)
    );

    always #10 clk <= ~clk;   // 50 MHz

    // -- ADC model: drives SDO, captures SDI ---------------------------------
    // NCodes is how many conversions are actually checked; the array carries
    // a few extra, harmless entries so the run-time margin below (which lets
    // the last checked sample's sample_valid land) can start one more
    // conversion without indexing off the end.
    localparam int NCodes  = 24;
    localparam int NSlots  = NCodes + 2;
    logic [11:0] codes [0:NSlots-1];
    int          conv_ptr;
    // B11 goes straight from codes[] to adc_dout at the conversion's start
    // (see below); code_word only ever needs to supply B10 downto B0.
    logic [10:0] code_word;

    logic [4:0] din_shift;
    int         rise_cnt;
    logic [5:0] captured_din [0:NSlots-1];

    int fall_cnt;

    initial begin
        // A spread of values, not just random ones: 0 and 4095 exercise the
        // all-zero/all-one shift patterns, which a bit-order mistake is most
        // likely to get right by accident on a mid-range value.
        codes[0]  = 12'h000;
        codes[1]  = 12'hFFF;
        codes[2]  = 12'h800;
        codes[3]  = 12'h7FF;
        codes[4]  = 12'hA5A;
        codes[5]  = 12'h5A5;
        for (int i = 6; i < NSlots; i++)
            codes[i] = 12'($urandom_range(0, 4095));
        conv_ptr = 0;
    end

    // One always block for the whole ADC model, distinguishing which edge
    // fired by the (post-edge) values of adc_convst/adc_sclk themselves --
    // the same pattern as an async-reset flip-flop's `posedge clk or negedge
    // rst_n`. Every variable here then has exactly one driver, which matters
    // for more than style: two always blocks racing to drive the same reg
    // from edges that can land in the same simulation time step is a real
    // testbench bug waiting to happen, not just a lint complaint.
    //
    // Also explicitly reset-aware, for a reason specific to simulation: cnt
    // (inside the DUT) powers up at 0 before its own reset branch has run
    // for the first time, which briefly makes adc_convst read high before
    // rst_n is ever sampled -- a real LTC2308 sees no such thing (nothing
    // toggles before the board's supplies and clock are stable), but this
    // model would otherwise treat that simulation-startup artifact as a
    // genuine first conversion and consume codes[0] before the test even
    // begins. Resetting conv_ptr alongside the DUT discards it cleanly
    // instead of quietly shifting every expected code by one.
    always @(posedge adc_convst or posedge adc_sclk or negedge adc_sclk or negedge rst_n) begin
        if (!rst_n) begin
            conv_ptr  <= 0;
            rise_cnt  <= 0;
            fall_cnt  <= 0;
            din_shift <= '0;
            adc_dout  <= 1'b0;
        end else if (adc_convst) begin
            // A new conversion starts: latch which code this model will
            // return for it, per the code stream above. MSB (B11) is
            // available immediately once the (simulated-complete) conversion
            // is ready; the master does not look at SDO until its own 1.6us
            // wait elapses, so exactly when this changes relative to that is
            // not what is under test here -- only that the right bit is
            // there once the master does look.
            code_word <= codes[conv_ptr][10:0];
            adc_dout  <= codes[conv_ptr][11];
            conv_ptr  <= conv_ptr + 1;
            rise_cnt  <= 0;
            fall_cnt  <= 0;
            din_shift <= '0;
        end else if (adc_sclk) begin
            // Rising edge: first 6 load the configuration word; the rest are
            // don't-care as far as this model's own behavior goes, but still
            // counted so din_shift is not polluted by the previous transfer
            // if code ever changed to care about it.
            if (rise_cnt < 6) din_shift <= 5'({din_shift, adc_din});
            if (rise_cnt == 5) captured_din[conv_ptr - 1] <= {din_shift, adc_din};
            rise_cnt <= rise_cnt + 1;
        end else begin
            // Falling edge: exposes the next bit, per Figure 9 -- B10 after
            // the 1st fall, ..., B0 after the 11th; the 12th returns SDO to
            // Hi-Z (modelled here as 0, since Verilator's 2-state simulation
            // can't drive Z and the master never reads adc_dout again this
            // period regardless).
            fall_cnt <= fall_cnt + 1;
            case (fall_cnt)
                0:  adc_dout <= code_word[10];
                1:  adc_dout <= code_word[9];
                2:  adc_dout <= code_word[8];
                3:  adc_dout <= code_word[7];
                4:  adc_dout <= code_word[6];
                5:  adc_dout <= code_word[5];
                6:  adc_dout <= code_word[4];
                7:  adc_dout <= code_word[3];
                8:  adc_dout <= code_word[2];
                9:  adc_dout <= code_word[1];
                10: adc_dout <= code_word[0];
                11: adc_dout <= 1'b0;
                default: ;
            endcase
        end
    end

    // -- collect the master's outputs ---------------------------------------
    logic [11:0] got_codes [0:NCodes-1];
    time         got_time  [0:NCodes-1];
    int          n_got = 0;

    always @(posedge clk) begin
        if (sample_valid) begin
            got_codes[n_got] <= sample_code;
            got_time[n_got]  <= $time;
            n_got            <= n_got + 1;
        end
    end

    // -- run and check --------------------------------------------------------
    int n_fail = 0;

    initial begin
        adc_dout = 1'b0;
        rst_n    = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // NCodes-1 full periods land NCodes-1 conversions (codes[0..NCodes-2]);
        // the +110 lets the NCodes-th conversion (codes[NCodes-1]) run far
        // enough into its own period for that period's sample_valid to land
        // too, without running a whole extra period beyond it -- which would
        // start a (NCodes+1)-th conversion this test never accounts for.
        repeat (Period * (NCodes - 1) + 110) @(posedge clk);

        if (n_got != NCodes - 1) begin
            n_fail++;
            $display("FAIL: got %0d samples, expected %0d (NCodes-1, first discarded)",
                     n_got, NCodes - 1);
        end

        // codes[0] must never appear: only codes[1..NCodes-1] are real
        // outputs, in order.
        for (int i = 0; i < n_got && i < NCodes - 1; i++) begin
            if (got_codes[i] !== codes[i + 1]) begin
                n_fail++;
                $display("FAIL sample %0d: expected %03h, got %03h", i, codes[i + 1], got_codes[i]);
            end
        end

        // Every transfer's DIN word, not just the first -- a config that
        // only held on power-up and drifted afterward would still pass a
        // single-shot check.
        for (int i = 0; i < conv_ptr; i++) begin
            if (captured_din[i] !== ExpectedDin) begin
                n_fail++;
                $display("FAIL DIN on conversion %0d: expected %06b, got %06b",
                         i, ExpectedDin, captured_din[i]);
            end
        end

        // Sample-to-sample spacing must be exactly one period, not merely
        // "close" -- a controller whose FSM count is off by a cycle would
        // still produce plausible-looking codes on this same stimulus.
        for (int i = 1; i < n_got; i++) begin
            time gap = got_time[i] - got_time[i - 1];
            if (gap != Period * 20) begin
                n_fail++;
                $display("FAIL spacing at sample %0d: %0t, expected %0dns", i, gap, Period * 20);
            end
        end

        if (n_fail == 0)
            $display("ALL %0d SAMPLES PASSED (first sample correctly discarded, DIN correct on %0d transfers)",
                     n_got, conv_ptr - 1);
        else
            $display("%0d CHECKS FAILED", n_fail);

        $finish;
    end

endmodule
