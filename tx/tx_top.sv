// Synthesizable top level for the TX chain: baseband IQ in, RF-rate IQ out,
// mirroring rx_top.sv with the interpolator and mixer order swapped.
// An INTERP-deep elastic queue captures the interpolator's burst of outputs
// and drains them into the mixer one per rotation, since the mixer accepts
// only one sample every ~19 clocks while idle.
// Egress is a stub: out_ready is only observed, and a stalled consumer sets
// a sticky out_overflow rather than corrupting the stream.

`timescale 1ns/1ps

module tx_top #(
    parameter int PHASE_BITS       = 24,
    parameter int PHASE_TRUNC_BITS = 14,
    parameter int ANG_BITS         = 17,
    parameter int DATA_BITS        = 16,
    parameter int CORDIC_BITS      = 18,
    parameter int MIX_BITS         = 17,
    parameter int ACC_BITS         = 40,
    parameter int INTERP           = 8   // must match fir_interp_coef_table.svh's FIR_INTERP_L
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Frequency control. Static in normal operation; a register interface
    // replaces this port once there is one.
    input  logic [PHASE_BITS-1:0]       phase_inc,

    // Baseband-rate input stream. in_ready is real backpressure: the next
    // sample waits until the elastic queue has drained (see header).
    input  logic                        in_valid,
    output logic                        in_ready,
    input  logic signed [DATA_BITS-1:0] bb_i,
    input  logic signed [DATA_BITS-1:0] bb_q,

    // RF-rate IQ egress (stub interface; see the header).
    output logic                        out_valid,
    input  logic                        out_ready,
    output logic signed [MIX_BITS-1:0]  rf_i,
    output logic signed [MIX_BITS-1:0]  rf_q,
    output logic                        out_overflow
);

    // -- interpolator ---------------------------------------------------
    logic interp_ready;
    logic interp_valid;
    logic signed [DATA_BITS-1:0] interp_i, interp_q;

    fir_interpolate #(
        .DATA_BITS (DATA_BITS),
        .ACC_BITS  (ACC_BITS)
    ) u_interp (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .xi        (bb_i),
        .xq        (bb_q),
        .in_ready  (interp_ready),
        .out_valid (interp_valid),
        .out_i     (interp_i),
        .out_q     (interp_q)
    );

    // -- elastic queue: interpolator's burst into the mixer's steady pace --
    localparam int QAddrW = $clog2(INTERP);
    localparam int QCntW  = QAddrW + 1;   // must represent INTERP itself, not just INTERP-1

    logic signed [DATA_BITS-1:0] q_i [0:INTERP-1];
    logic signed [DATA_BITS-1:0] q_q [0:INTERP-1];
    logic [QAddrW-1:0] wr_idx, rd_idx;
    logic [QCntW-1:0]  q_count;

    logic mixer_busy;
    wire  q_has_data = (q_count != QCntW'(0));
    wire  q_pop      = q_has_data && !mixer_busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_idx <= '0;
        end else if (interp_valid) begin
            q_i[wr_idx] <= interp_i;
            q_q[wr_idx] <= interp_q;
            wr_idx      <= wr_idx + 1'b1;   // wraps mod INTERP (power of two)
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_idx <= '0;
        end else if (q_pop) begin
            rd_idx <= rd_idx + 1'b1;
        end
    end

    // interp_valid and q_pop are usually mutually exclusive, but the count
    // update handles a simultaneous push and pop correctly regardless.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_count <= '0;
        end else begin
            case ({interp_valid, q_pop})
                2'b10:   q_count <= q_count + QCntW'(1);
                2'b01:   q_count <= q_count - QCntW'(1);
                default: q_count <= q_count;
            endcase
        end
    end

    // Requires both interp_ready and an empty queue: idle alone would let a
    // new sample overwrite queue slots the mixer has not drained yet.
    assign in_ready = interp_ready && !q_has_data;

    // -- mixer (up-convert) -----------------------------------------------
    logic mix_valid;
    logic signed [MIX_BITS-1:0] mix_i, mix_q;

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
        // This top level is the TX chain, so the shared front end is tied
        // to up-convert here. The TT wrapper drives it from a pin instead.
        .downconvert (1'b0),
        .in_valid    (q_pop),
        .xi          (q_i[rd_idx]),
        .xq          (q_q[rd_idx]),
        .busy        (mixer_busy),
        .out_valid   (mix_valid),
        .mix_i       (mix_i),
        .mix_q       (mix_q)
    );

    // -- egress --------------------------------------------------------
    assign out_valid = mix_valid;
    assign rf_i      = mix_i;
    assign rf_q      = mix_q;

    // Sticky: a consumer that could not take a sample dropped it.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_overflow <= 1'b0;
        else if (out_valid && !out_ready)
            out_overflow <= 1'b1;
    end

endmodule
