// The DE1-SoC design proper: the RX chain feeding an Avalon-MM FIFO the
// HPS drains over the lightweight bridge. DE1_SoC.sv wraps this with the
// Platform Designer system and the board's pins.
//
// SW[0] low replays an on-chip stimulus ROM and checks it against the
// reference model; SW[0] high digitises a live signal through the LTC2308.
// Both modes fill the FIFO, so the self-test also covers the egress path.
//
// The host picks the sample rate and the LO through the FIFO's registers.
// The self-test forces the decimated tap, matching its expected outputs.
//
// -- user I/O -------------------------------------------------------------
//   KEY[0]     reset, active low (debounced on the board)
//   SW[0]      0 = ROM self-test, 1 = live ADC capture
//   LEDR[0]    done: all expected self-test outputs received
//   LEDR[1]    pass: lit alone = success
//   LEDR[2]    fail: an output mismatched
//   LEDR[3]    rx_top asserted out_overflow
//   LEDR[4]    an IQ pair was dropped on the way to the HPS
//   LEDR[5]    a conversion landed before the datapath took the previous one
//   LEDR[6]    live mode
//   LEDR[7]    the host has enabled streaming
//   LEDR[9]    heartbeat
//   HEX1:HEX0  mismatch count, or live FIFO level
//   HEX3:HEX2  outputs received, or live dropped-pair count
//   HEX5:HEX4  blank
//
// Regenerate the ROM with de1soc/gen_selftest_rom.py after a config change.

`timescale 1ns/1ps
`include "selftest_rom.svh"

module de1soc_core #(
    // The LO the ROM's expected outputs were generated against, and the
    // value PHASE_INC resets to. Overriding it invalidates the expected
    // outputs; tb_de1soc_negative does exactly that.
    parameter logic [23:0] PHASE_INC = `SELFTEST_PHASE_INC,

    // 4096 words is about 10 ms at the full 400 kS/s rate.
    parameter int FIFO_DEPTH = 4096
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

    // LTC2308 ADC.
    output logic        ADC_CONVST,
    output logic        ADC_SCLK,
    output logic        ADC_DIN,
    input  logic        ADC_DOUT,

    // Avalon-MM slave, driven by the HPS through the lightweight bridge.
    input  logic [2:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    output logic        avs_readdatavalid,
    output logic        avs_waitrequest,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata
);

    localparam int NStim    = `SELFTEST_N_STIM;
    localparam int NOut     = `SELFTEST_N_OUT;
    localparam int DataBits = `SELFTEST_DATA_BITS;
    localparam int OutBits  = `SELFTEST_OUT_BITS;

    // The code is left-justified into the datapath word.
    initial begin
        if (DataBits < 12)
            $fatal(1, "DE1_SoC: DataBits=%0d is narrower than the LTC2308's 12 bits", DataBits);
    end

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

    // Unused board inputs, named so lint does not flag them.
    wire _unused_ok = &{1'b0, SW[9:1], KEY[3:1]};

    wire live_mode = SW[0];

    // -- ADC ---------------------------------------------------------------
    wire        adc_sample_valid;
    wire [11:0] adc_code;

    ltc2308_ctrl u_adc (
        .clk          (clk),
        .rst_n        (rst_n),
        .adc_convst   (ADC_CONVST),
        .adc_sclk     (ADC_SCLK),
        .adc_din      (ADC_DIN),
        .adc_dout     (ADC_DOUT),
        .sample_valid (adc_sample_valid),
        .sample_code  (adc_code)
    );

    // CH0 is unipolar straight binary over 0-4.096 V. Inverting the MSB
    // subtracts mid-scale; the result is left-justified into the datapath.
    wire signed [11:0]         adc_signed = {~adc_code[11], adc_code[10:0]};
    wire signed [DataBits-1:0] adc_sample = DataBits'(adc_signed) <<< (DataBits - 12);

    // Single-ended, so the input is real and Q is zero.
    logic signed [DataBits-1:0] adc_hold;
    logic                       sample_pending;
    logic                       adc_overrun;

    // -- stimulus playback (self-test mode) --------------------------------
    logic [SiBits-1:0] si;
    wire               stim_left = (si < SiBits'(NStim));

    // Both modes run at the converter's 400 kS/s tick, which free-runs
    // regardless of mode.
    wire in_ready;
    wire in_valid = sample_pending && (live_mode || stim_left);
    wire accept   = in_valid && in_ready;

    // Held in range while draining: indexing a localparam array past its end
    // is an X in simulation, and the value is unused once stim_left drops.
    wire [SiIdxBits-1:0] si_idx = stim_left ? si[SiIdxBits-1:0] : '0;

    wire signed [DataBits-1:0] rx_i = live_mode ? adc_hold : SELFTEST_STIM_I[si_idx];
    wire signed [DataBits-1:0] rx_q = live_mode ? '0       : SELFTEST_STIM_Q[si_idx];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_hold       <= '0;
            sample_pending <= 1'b0;
            adc_overrun    <= 1'b0;
        end else begin
            if (sample_pending && accept)
                sample_pending <= 1'b0;

            if (adc_sample_valid) begin
                // Datapath fell behind; the older sample is replaced.
                // Live mode only: the self-test leaves samples unconsumed.
                if (sample_pending && live_mode && !accept)
                    adc_overrun <= 1'b1;
                adc_hold       <= adc_sample;
                sample_pending <= 1'b1;
            end
        end
    end

    // -- the design under test --------------------------------------------
    // Host-written control, from the register file below.
    wire        ctrl_tap_full;
    wire        stream_en;
    wire [23:0] ctrl_phase_inc;
    wire [15:0] fifo_level, fifo_drops;
    wire        fifo_overflow;

    // The self-test's expected outputs are FIR outputs, so it pins the tap
    // regardless of what the host asked for.
    wire tap_full = live_mode && ctrl_tap_full;

    wire                        out_valid;
    wire signed [OutBits-1:0]   iq_i, iq_q;
    wire                        out_overflow;

    rx_top u_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .phase_inc    (live_mode ? ctrl_phase_inc : PHASE_INC),
        .in_valid     (in_valid),
        .in_ready     (in_ready),
        .adc_i        (rx_i),
        .adc_q        (rx_q),
        .tap_full     (tap_full),
        .out_valid    (out_valid),
        // The FIFO drops and flags rather than stalling.
        .out_ready    (1'b1),
        .iq_i         (iq_i),
        .iq_q         (iq_q),
        .out_overflow (out_overflow)
    );

    // -- egress: buffer for the HPS ----------------------------------------
    iq_avalon_fifo #(
        .DEPTH          (FIFO_DEPTH),
        .DATA_BITS      (OutBits),
        .PHASE_BITS     (24),
        .PHASE_INC_INIT (PHASE_INC)
    ) u_egress (
        .clk           (clk),
        .rst_n         (rst_n),
        .avs_address   (avs_address),
        .avs_read      (avs_read),
        .avs_readdata  (avs_readdata),
        .avs_readdatavalid (avs_readdatavalid),
        .avs_waitrequest   (avs_waitrequest),
        .avs_write     (avs_write),
        .avs_writedata (avs_writedata),
        .iq_valid      (out_valid),
        .iq_i          (iq_i),
        .iq_q          (iq_q),
        .tap_full      (ctrl_tap_full),
        .enable        (stream_en),
        .phase_inc     (ctrl_phase_inc),
        .level         (fifo_level),
        .drops         (fifo_drops),
        .overflow      (fifo_overflow)
    );

    // -- compare against the reference model's answer ----------------------
    // Self-test only: live capture has no expected output.
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
            if (accept && !live_mode) si <= si + 1'b1;

            if (out_valid && !done && !live_mode) begin
                if (mismatch && n_bad != 8'hFF)  n_bad  <= n_bad + 1'b1;
                if (n_recv != 8'hFF)             n_recv <= n_recv + 1'b1;
                if (oi == OiBits'(NOut - 1)) done <= 1'b1;
                else                         oi   <= oi + 1'b1;
            end
        end
    end

    // -- reporting ---------------------------------------------------------
    // Free-running, so a stopped clock is distinguishable from no output.
    logic [24:0] beat;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) beat <= '0;
        else        beat <= beat + 1'b1;
    end

    assign LEDR[0]   = done;
    assign LEDR[1]   = done && (n_bad == '0);
    assign LEDR[2]   = (n_bad != '0);
    assign LEDR[3]   = out_overflow;
    assign LEDR[4]   = fifo_overflow;
    assign LEDR[5]   = adc_overrun;
    assign LEDR[6]   = live_mode;
    assign LEDR[7]   = stream_en;
    assign LEDR[8]   = 1'b0;
    assign LEDR[9]   = beat[24];

    // Live mode shows how the link is keeping up, since the self-test
    // counters never move.
    wire [7:0] hex_lo = live_mode ? fifo_level[15:8] : n_bad;
    wire [7:0] hex_hi = live_mode ? fifo_drops[7:0]  : n_recv;

    hex7seg h0 (.value(hex_lo[3:0]), .blank(1'b0), .seg(HEX0));
    hex7seg h1 (.value(hex_lo[7:4]), .blank(1'b0), .seg(HEX1));
    hex7seg h2 (.value(hex_hi[3:0]), .blank(1'b0), .seg(HEX2));
    hex7seg h3 (.value(hex_hi[7:4]), .blank(1'b0), .seg(HEX3));
    hex7seg h4 (.value(4'h0), .blank(1'b1), .seg(HEX4));
    hex7seg h5 (.value(4'h0), .blank(1'b1), .seg(HEX5));

endmodule
