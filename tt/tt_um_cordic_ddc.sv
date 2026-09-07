// TinyTapeout wrapper: the CORDIC NCO and fused mixer behind a byte-serial
// interface that fits TinyTapeout's 8 in / 8 out / 8 bidirectional pins.
// The 65-bit input and 36-bit output cannot be pinned out directly, so
// samples and results move as serial byte streams that overlap the CORDIC's
// own 19-clock rotation, costing about 22 clocks per sample.
// The decimating FIR stays off-chip: its 63-tap delay line alone is over a
// thousand flip-flops, larger than this whole design.
//
// -- pin map ----------------------------------------------------------------
//   ui_in[7:0]    byte in       sample or config byte
//   uo_out[7:0]   byte out      result byte
//   uio_in[0]     i_valid       in:  ui_in holds a valid byte this clock
//   uio_in[1]     i_cfg         in:  1 = config byte, 0 = sample byte
//   uio_out[2]    o_valid       out: uo_out holds a valid byte this clock
//   uio_out[3]    i_ready       out: a sample byte may be sent this clock
//   uio_out[4]    o_ovf         out: sticky -- a result was overwritten unread
//   uio_in[5]     i_down        in:  1 = down-convert (RX), 0 = up-convert (TX)
//   uio[7:6]      unused, driven low
//
// i_down is a pin, not a config bit, because direction is chosen per sample.
// It is sampled on the clock the last sample byte lands, so RX and TX
// samples can interleave through the one rotator.
//
// -- framing ----------------------------------------------------------------
// All multi-byte values are big-endian (most significant byte first).
//   config : PHASE_BITS/8 bytes -> phase_inc. Free-running shift register, so
//            no framing is needed; send the bytes back to back and the value
//            is correct once the last one lands.
//   sample : 2*DATA_BITS/8 bytes -> {xi, xq}. A rotation starts on the last.
//   result : ceil(2*MIX_BITS/8) bytes -> {pad, mix_i, mix_q}, emitted back to
//            back with o_valid high.
//
// Results are muxed directly from the mixer's output registers instead of a
// copied shift register, saving about 40 flip-flops. They remain valid for
// the full 19-clock rotation, far longer than the 5 clocks needed to read
// them out, and o_ovf latches if a consumer misses that window.

`timescale 1ns/1ps

module tt_um_cordic_ddc #(
    parameter int PHASE_BITS       = 24,
    parameter int PHASE_TRUNC_BITS = 14,
    parameter int ANG_BITS         = 17,
    parameter int DATA_BITS        = 16,
    parameter int CORDIC_BITS      = 18,
    parameter int MIX_BITS         = 17
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam int CfgBytes  = PHASE_BITS / 8;
    localparam int SampBits  = 2 * DATA_BITS;
    localparam int SampBytes = SampBits / 8;
    localparam int OutBits   = 2 * MIX_BITS;
    localparam int OutBytes  = (OutBits + 7) / 8;
    localparam int OutPad    = OutBytes * 8 - OutBits;

    localparam int SampCntW  = $clog2(SampBytes);
    localparam int OutCntW   = $clog2(OutBytes + 1);

    // ena is high whenever this design is selected; nothing here needs to
    // gate on it, so it is intentionally unused.
    wire _unused_ena = ena;
    wire [1:0] _unused_uio = uio_in[7:6];

    wire i_valid = uio_in[0];
    wire i_cfg   = uio_in[1];
    wire i_down  = uio_in[5];

    // -- input: one shift register serves both config and sample bytes ------
    // They never overlap, so sharing costs nothing and saves a register.
    logic [SampBits-1:0]   in_sr;
    logic [PHASE_BITS-1:0] phase_inc;
    logic [SampCntW-1:0]   samp_cnt;
    // Latched with the last sample byte: ddc_in_valid asserts one clock
    // later, by which point i_down and ui_in may have already moved on.
    logic                  down_reg;

    logic                  ddc_in_valid;
    wire                   ddc_busy;
    wire                   ddc_out_valid;

    // i_ready gates only on ddc_busy, not on out_active: mix_i/mix_q hold
    // for 19 clocks, far longer than the 5 needed to read them out, so
    // input and output safely overlap.
    logic                  out_active;
    wire                   i_ready = !ddc_busy;
    wire                   take    = i_valid && (i_cfg || i_ready);

    wire samp_last = (samp_cnt == SampCntW'(SampBytes - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_sr        <= '0;
            phase_inc    <= '0;
            samp_cnt     <= '0;
            down_reg     <= 1'b1;
            ddc_in_valid <= 1'b0;
        end else begin
            ddc_in_valid <= 1'b0;
            if (take) begin
                if (i_cfg) begin
                    // Free-running: after CfgBytes bytes the value is correct,
                    // so no counter or framing is needed.
                    phase_inc <= {phase_inc[PHASE_BITS-9:0], ui_in};
                end else begin
                    in_sr <= {in_sr[SampBits-9:0], ui_in};
                    if (samp_last) begin
                        samp_cnt     <= '0;
                        down_reg     <= i_down;
                        ddc_in_valid <= 1'b1;
                    end else begin
                        samp_cnt <= samp_cnt + 1'b1;
                    end
                end
            end
        end
    end

    // in_sr already holds the full word by the cycle ddc_in_valid is high,
    // so xi/xq read from the register, not from ui_in, which has moved on.
    wire signed [DATA_BITS-1:0] xi = in_sr[SampBits-1 -: DATA_BITS];
    wire signed [DATA_BITS-1:0] xq = in_sr[DATA_BITS-1 : 0];

    wire signed [MIX_BITS-1:0] mix_i, mix_q;

    ddc_frontend #(
        .PHASE_BITS       (PHASE_BITS),
        .PHASE_TRUNC_BITS (PHASE_TRUNC_BITS),
        .ANG_BITS         (ANG_BITS),
        .DATA_BITS        (DATA_BITS),
        .CORDIC_BITS      (CORDIC_BITS),
        .MIX_BITS         (MIX_BITS)
    ) u_ddc (
        .clk         (clk),
        .rst_n       (rst_n),
        .phase_inc   (phase_inc),
        .downconvert (down_reg),
        .in_valid    (ddc_in_valid),
        .xi          (xi),
        .xq          (xq),
        .busy        (ddc_busy),
        .out_valid   (ddc_out_valid),
        .mix_i       (mix_i),
        .mix_q       (mix_q)
    );

    // -- output: mux bytes straight out of the mixer's result registers -----
    logic [OutCntW-1:0] out_cnt;
    logic               ovf;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_cnt    <= '0;
            out_active <= 1'b0;
            ovf        <= 1'b0;
        end else begin
            if (ddc_out_valid) begin
                // A new result landed while the previous one was still going
                // out: the consumer missed its window.
                if (out_active) ovf <= 1'b1;
                out_cnt    <= '0;
                out_active <= 1'b1;
            end else if (out_active) begin
                if (out_cnt == OutCntW'(OutBytes - 1)) begin
                    out_active <= 1'b0;
                    out_cnt    <= '0;
                end else begin
                    out_cnt <= out_cnt + 1'b1;
                end
            end
        end
    end

    wire [OutBytes*8-1:0] out_word = {{OutPad{1'b0}}, mix_i, mix_q};

    // int' cast forces the subtraction to full width; out_cnt alone is only
    // OutCntW bits and would truncate the constant.
    assign uo_out = out_active
                  ? out_word[(OutBytes - 1 - int'(out_cnt)) * 8 +: 8]
                  : 8'h00;

    assign uio_out = {3'b000, ovf, i_ready, out_active, 2'b00};
    assign uio_oe  = 8'b0001_1100;   // bits 2,3,4 drive; the rest are inputs

endmodule
