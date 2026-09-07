// Self-checking testbench for ltc2308_ctrl.
//
// There is no LTC2308 to test against, so this testbench *is* the ADC: an
// SPI slave model built directly from the datasheet's Figure 9 (short
// CONVST pulse) timing, driving SDO from a queue of programmed 12-bit codes
// and capturing whatever SDI word the master sends. That makes this a check
// of the *protocol*, not a comparison against silicon -- the real test is
// deferred until a board and the part are on hand.
//
// The model is one always block sensitized directly to adc_convst/adc_sclk's
// real edges (plus reset), so every signal it drives has exactly one writer
// and its reactions are correctly ordered relative to the signal transitions
// that cause them -- sampling those edges indirectly instead (comparing
// against a posedge-clk-registered copy) races the DUT's own combinational
// path from `cnt` to adc_sclk within the same clock edge, and shifted every
// captured bit by one position during development. Verilator's `--timing`
// (already used by every sim script here) lets the CONVST branch express
// tCONV as a literal `repeat (N) @(posedge clk)` wait before revealing SDO,
// so the model can hold SDO at a *wrong* value until that delay elapses --
// which an instantaneous reaction to adc_convst could not represent.
//
// Checked, over many back-to-back samples:
//   - SDO is not revealed until this model's own tCONV delay elapses, so a
//     master that started reading early would see stale data and fail
//   - SDI is stable a full clock *before* the edge that samples it, not
//     merely stable *by* that edge -- the same margin the real part expects
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
    // ltc2308_ctrl's own ShiftBegin: how many `posedge clk`s this model
    // waits, from the CONVST edge that triggers the branch below, before
    // revealing the true MSB.
    localparam int TconvWaitCycles = 80;
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
    // NCodes conversions are checked; NSlots = NCodes+2 pads the array for
    // the run-length margin below, which starts one extra conversion.
    localparam int NCodes = 24;
    localparam int NSlots = NCodes + 2;
    logic [11:0] codes [0:NSlots-1];
    int          conv_ptr;
    // B11 goes straight from codes[] to adc_dout when it is revealed (see
    // below); code_word only ever needs to supply B10 downto B0.
    logic [10:0] code_word;
    logic [11:0] pending_code;

    logic [4:0] din_shift;
    int         rise_cnt;
    logic [5:0] captured_din [0:NSlots-1];

    int fall_cnt;

    // Independent of the main model below: a plain 1-cycle-delayed copy of
    // adc_din, its own single-driver process, used only for the setup-time
    // check where "din_shift's own value hasn't changed yet" is not enough
    // to prove din itself was already stable.
    logic prev_din;
    always @(posedge clk) prev_din <= adc_din;

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

    int n_fail = 0;

    // The whole model, sensitized directly to the real edges it reacts to
    // (see the header note on why not posedge clk). A new conversion holds
    // adc_dout at whatever it last was -- the previous conversion's final
    // bit -- until the tCONV wait below elapses, so a master that samples
    // early gets stale data rather than a suspiciously correct answer.
    always @(posedge adc_convst or posedge adc_sclk or negedge adc_sclk or negedge rst_n) begin
        if (!rst_n) begin
            conv_ptr  <= 0;
            rise_cnt  <= 0;
            fall_cnt  <= 0;
            din_shift <= '0;
            adc_dout  <= 1'b0;
        end else if (adc_convst) begin
            // pending_code is the one variable here that must be blocking:
            // it is read again immediately below, after the tCONV wait, and
            // needs the value fixed *now* rather than deferred.
            pending_code = codes[conv_ptr];
            conv_ptr     <= conv_ptr + 1;
            rise_cnt     <= 0;
            fall_cnt     <= 0;
            din_shift    <= '0;
            repeat (TconvWaitCycles) @(posedge clk);
            adc_dout  <= pending_code[11];
            code_word <= pending_code[10:0];
        end else if (adc_sclk) begin
            // Rising edge: first 6 load the configuration word; the rest
            // are don't-care as far as this model's own behavior goes, but
            // still counted so din_shift is not polluted by the previous
            // transfer if code ever changed to care about it. Nonblocking
            // here matters, not just style: the capture below needs
            // din_shift's value from *before* this same edge's update, and
            // a blocking `din_shift = ...` above it would already have
            // folded this edge's bit in twice.
            //
            // Setup check: adc_din must already have held this value one
            // full clock ago (prev_din, from the standalone process above),
            // not merely as of this edge -- adc_din changing coincident
            // with the edge that samples it (as an earlier version of the
            // master did) fails this.
            if (adc_din !== prev_din) begin
                n_fail++;
                $display("FAIL setup: adc_din changed on the same edge that SCK sampled it (conversion %0d, bit %0d)",
                          conv_ptr - 1, rise_cnt);
            end
            if (rise_cnt < 6) din_shift <= 5'({din_shift, adc_din});
            if (rise_cnt == 5) captured_din[conv_ptr - 1] <= {din_shift, adc_din};
            rise_cnt <= rise_cnt + 1;
        end else begin
            // Falling edge: exposes the next bit, per Figure 9 -- B10 after
            // the 1st fall, ..., B0 after the 11th; the 12th returns SDO to
            // Hi-Z (modelled here as 0, since Verilator's 2-state simulation
            // can't drive Z and the master never reads adc_dout again this
            // period regardless). Nonblocking fall_cnt, so the case below
            // selects on this edge's bit, not the next one's.
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
    initial begin
        adc_dout = 1'b0;
        rst_n    = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        // NCodes-1 full periods, plus enough of the NCodes-th for its own
        // sample_valid to land -- not a whole extra period, which would
        // start an (NCodes+1)-th conversion this test doesn't account for.
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
            $display("ALL %0d SAMPLES PASSED (first sample correctly discarded, DIN correct on %0d transfers, SDI setup checked)",
                     n_got, conv_ptr - 1);
        else begin
            $display("%0d CHECKS FAILED", n_fail);
            $fatal(1, "tb_ltc2308_ctrl: %0d check(s) failed", n_fail);
        end

        $finish;
    end

endmodule
