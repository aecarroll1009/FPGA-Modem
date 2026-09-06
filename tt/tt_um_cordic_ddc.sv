// TinyTapeout wrapper: the CORDIC NCO + fused mixer behind a byte-serial
// interface that fits TinyTapeout's 8 in / 8 out / 8 bidirectional pins.
//
// The parallel core needs 65 input and 36 output bits, so it cannot be pinned
// out directly. It does not have to be: the iterative CORDIC spends 19 clocks
// per sample, and the byte traffic is 4 bytes in and 5 bytes out, which shift
// concurrently on separate ports. So serialisation hides entirely inside the
// rotation and costs no throughput -- the CORDIC stays the bottleneck.
//
// The decimating FIR is deliberately NOT here. Its 63-deep sample delay line
// alone is over a thousand flip-flops, larger than this whole design; it stays
// off-chip. What tapes out is the part that is actually novel: NCO + mixer.
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
// i_down is a pin rather than a config-register bit because the direction is
// per-sample: it is sampled on the clock the last sample byte lands, so a host
// can interleave RX and TX samples through the one rotator if it wants to.
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
// Results are muxed straight out of the mixer's own output registers rather
// than copied into a shift register, which saves 40 flip-flops. They stay
// valid until the next rotation completes -- 19 clocks, against 5 to read them
// out -- and o_ovf latches if a consumer ever misses that window.

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
    // Latched alongside the last sample byte. ddc_in_valid is registered, so
    // it asserts one clock after that byte lands and the i_down pin may have
    // moved on by then -- the same reason xi/xq are read from in_sr and not
    // from ui_in.
    logic                  down_reg;

    logic                  ddc_in_valid;
    wire                   ddc_busy;
    wire                   ddc_out_valid;

    // Accept a sample byte whenever the core can take the rotation it will
    // start. Deliberately NOT gated on out_active: input arrives on ui_in and
    // results leave on uo_out, so a host can shift the next sample in while
    // the current result shifts out. That is safe because results are muxed
    // from mix_i/mix_q, which hold until the next rotation completes 19 clocks
    // later -- far longer than the 5 clocks needed to read them out. Gating on
    // out_active as well would serialise the two and cost ~5 clocks a sample.
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

    // The last byte's shift and ddc_in_valid land on the same clock edge, so
    // by the cycle in_valid is high in_sr already holds the whole word. Read
    // it from the register, not from ui_in, which has moved on by then.
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

    // int' cast so the subtraction happens at full width -- out_cnt alone is
    // OutCntW bits and would truncate the constant.
    assign uo_out = out_active
                  ? out_word[(OutBytes - 1 - int'(out_cnt)) * 8 +: 8]
                  : 8'h00;

    assign uio_out = {3'b000, ovf, i_ready, out_active, 2'b00};
    assign uio_oe  = 8'b0001_1100;   // bits 2,3,4 drive; the rest are inputs

endmodule
