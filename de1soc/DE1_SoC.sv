// DE1-SoC board top level: the RX chain, self-testing against the reference
// model on real silicon.
//
// This is the first bring-up stage, and it deliberately contains no ADC. The
// datapath, the analog front end, and the converter interface are three
// independent sources of failure; wiring them up together means a wrong
// answer has three suspects. Here the stimulus comes from an on-chip ROM and
// the expected response comes from the same reference model the simulation
// testbenches use, so a programmed board answers exactly one question: does
// the synthesized datapath produce, on hardware, the bits the model says it
// should? When the LTC2308 controller lands, the datapath is already ruled
// out.
//
// -- what it does ---------------------------------------------------------
// Plays SELFTEST_N_STIM samples into rx_top as fast as it will take them
// (in_valid is held high; ddc_frontend's busy paces it at ~19 clocks per
// sample), compares every decimated output against the ROM, and reports.
//
// -- user I/O -------------------------------------------------------------
//   KEY[0]     reset, active low -- the board's buttons read 0 when pressed
//              and are already debounced by a Schmitt trigger, so this needs
//              no conditioning
//   LEDR[0]    done: all expected outputs were received
//   LEDR[1]    pass: done and every output matched (lit alone = success)
//   LEDR[2]    fail: at least one output mismatched
//   LEDR[3]    overflow: rx_top asserted out_overflow (see rx_top.sv)
//   LEDR[9]    heartbeat, so a dead clock or held reset is visible
//   HEX1:HEX0  mismatch count, hex
//   HEX3:HEX2  outputs received, hex
//   HEX5:HEX4  blank
//
// -- ADC port -------------------------------------------------------------
// The LTC2308 pins are declared and parked at idle rather than left out, so
// the pin assignments are in place and the board is not driving the ADC
// while there is no controller to drive it properly.
//
// Reference model: cordic/reference/ddc_reference.py. Regenerate the ROM
// with de1soc/gen_selftest_rom.py after any config change.

`timescale 1ns/1ps
`include "selftest_rom.svh"

module DE1_SoC #(
    // The LO the board runs at. Defaults to the value the self-test ROM was
    // generated against -- override it and the expected outputs no longer
    // apply, which is exactly what tb_de1soc_negative does to prove the
    // comparison below is real.
    parameter logic [23:0] PHASE_INC = `SELFTEST_PHASE_INC
) (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,
    output logic [6:0]  HEX0,
    output logic [6:0]  HEX1,
    output logic [6:0]  HEX2,
    output logic [6:0]  HEX3,
    output logic [6:0]  HEX4,
    output logic [6:0]  HEX5,

    // LTC2308 ADC -- pinned out, parked until the controller exists.
    output logic        ADC_CONVST,
    output logic        ADC_SCLK,
    output logic        ADC_DIN,
    input  logic        ADC_DOUT
);

    localparam int NStim    = `SELFTEST_N_STIM;
    localparam int NOut     = `SELFTEST_N_OUT;
    localparam int DataBits = `SELFTEST_DATA_BITS;
    localparam int OutBits  = `SELFTEST_OUT_BITS;

    // Counters must reach NStim/NOut themselves (the "all sent" and "all
    // received" states), so they are one bit wider than the array indices
    // derived from them -- hence the separate *IdxBits below rather than
    // indexing with the counter directly.
    localparam int SiBits    = $clog2(NStim + 1);
    localparam int OiBits    = $clog2(NOut + 1);
    localparam int SiIdxBits = $clog2(NStim);
    localparam int OiIdxBits = $clog2(NOut);

    wire clk   = CLOCK_50;
    wire rst_n = KEY[0];

    // Unused board inputs, named so lint does not flag them and a reader can
    // see they are unconnected on purpose rather than by omission.
    wire _unused_ok = &{1'b0, SW, KEY[3:1], ADC_DOUT};

    assign ADC_CONVST = 1'b0;
    assign ADC_SCLK   = 1'b0;
    assign ADC_DIN    = 1'b0;

    // -- stimulus playback ------------------------------------------------
    logic [SiBits-1:0] si;
    wire               stim_left = (si < SiBits'(NStim));

    wire in_ready;
    wire in_valid = stim_left;
    wire accept   = in_valid && in_ready;

    // Held in range while draining: indexing a localparam array past its end
    // is an X in simulation, and the value is unused once stim_left drops.
    wire [SiIdxBits-1:0] si_idx = stim_left ? si[SiIdxBits-1:0] : '0;

    logic signed [DataBits-1:0] adc_i, adc_q;
    assign adc_i = SELFTEST_STIM_I[si_idx];
    assign adc_q = SELFTEST_STIM_Q[si_idx];

    // -- the design under test --------------------------------------------
    wire                        out_valid;
    wire signed [OutBits-1:0]   iq_i, iq_q;
    wire                        out_overflow;

    rx_top u_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .phase_inc    (PHASE_INC),
        .in_valid     (in_valid),
        .in_ready     (in_ready),
        .adc_i        (adc_i),
        .adc_q        (adc_q),
        .out_valid    (out_valid),
        // Nothing downstream can stall on this board, so the consumer is
        // always ready and out_overflow should never latch. It is surfaced
        // on an LED anyway -- if it ever lights, the assumption is wrong.
        .out_ready    (1'b1),
        .iq_i         (iq_i),
        .iq_q         (iq_q),
        .out_overflow (out_overflow)
    );

    // -- compare against the reference model's answer ----------------------
    logic [OiBits-1:0] oi;      // index of the next expected output
    logic [7:0]        n_bad;   // mismatches, saturating so it never wraps to 0
    logic [7:0]        n_recv;  // outputs received, saturating for the same reason
    logic              done;

    wire [OiIdxBits-1:0] oi_idx = (oi < OiBits'(NOut)) ? oi[OiIdxBits-1:0] : '0;
    wire mismatch = (iq_i !== SELFTEST_OUT_I[oi_idx])
                 || (iq_q !== SELFTEST_OUT_Q[oi_idx]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            si     <= '0;
            oi     <= '0;
            n_bad  <= '0;
            n_recv <= '0;
            done   <= 1'b0;
        end else begin
            if (accept) si <= si + 1'b1;

            if (out_valid && !done) begin
                if (mismatch && n_bad != 8'hFF)  n_bad  <= n_bad + 1'b1;
                if (n_recv != 8'hFF)             n_recv <= n_recv + 1'b1;
                if (oi == OiBits'(NOut - 1)) done <= 1'b1;
                else                         oi   <= oi + 1'b1;
            end
        end
    end

    // -- reporting ---------------------------------------------------------
    // Free-running so a held reset or a stopped clock is distinguishable
    // from a design that simply produced nothing.
    logic [24:0] beat;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) beat <= '0;
        else        beat <= beat + 1'b1;
    end

    assign LEDR[0]   = done;
    assign LEDR[1]   = done && (n_bad == '0);
    assign LEDR[2]   = (n_bad != '0);
    assign LEDR[3]   = out_overflow;
    assign LEDR[8:4] = '0;
    assign LEDR[9]   = beat[24];

    hex7seg h0 (.value(n_bad[3:0]),  .blank(1'b0), .seg(HEX0));
    hex7seg h1 (.value(n_bad[7:4]),  .blank(1'b0), .seg(HEX1));
    hex7seg h2 (.value(n_recv[3:0]), .blank(1'b0), .seg(HEX2));
    hex7seg h3 (.value(n_recv[7:4]), .blank(1'b0), .seg(HEX3));
    hex7seg h4 (.value(4'h0), .blank(1'b1), .seg(HEX4));
    hex7seg h5 (.value(4'h0), .blank(1'b1), .seg(HEX5));

endmodule
