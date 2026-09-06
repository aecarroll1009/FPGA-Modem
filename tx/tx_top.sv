// Synthesizable top level for the TX chain: baseband IQ in, RF-rate IQ out.
//
// Mirror of rx/rx_top.sv, with the filter and mixer swapping order: baseband
// samples interpolate first, then up-convert, instead of down-convert then
// decimate.
//
// -- the rate mismatch this module exists to bridge -----------------------
// fir_interpolate produces its INTERP outputs for one baseband sample as
// fast as its own MAC engine allows (no pacing built in -- see its header),
// which is far faster than the mixer can accept them: the mixer is
// iterative and absorbs one sample per rotation, ~19 clocks, not one per
// clock. Wiring interp's out_valid straight to the mixer's in_valid would
// silently drop most of the 8 samples, since the mixer only samples
// in_valid while idle and spends most of its time busy.
//
// The fix is a small elastic buffer: every interpolator output is captured
// into an INTERP-deep queue as it arrives, and drained into the mixer one
// entry per rotation, at whatever pace the mixer allows. Order is preserved
// because the interpolator always produces phases 0..INTERP-1 in that
// order, so a plain write-pointer/read-pointer queue (not a priority
// structure) is enough. The next baseband sample is not accepted until the
// queue is fully drained *and* the interpolator is idle -- draining lags
// well behind computing, so the drain condition is the binding one -- which
// is what makes the two blocks' very different paces safe to compose.
//
// Egress is deliberately a stub, same reasoning as rx_top: no PHY is chosen
// yet, so out_ready is an observation point and a stalled consumer is
// reported via a sticky out_overflow rather than silently corrupting the
// stream. Ingress backpressure (in_ready) is real, same as rx_top's.

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

    // Baseband-rate input stream. in_ready is real backpressure: see the
    // header note on why the next sample must wait for the queue to drain.
    input  logic                        in_valid,
    output logic                        in_ready,
    input  logic signed [DATA_BITS-1:0] bb_i,
    input  logic signed [DATA_BITS-1:0] bb_q,

    // RF-rate IQ egress (stub interface -- see the header note).
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

    // interp_valid and q_pop are mutually exclusive in the steady flow this
    // module relies on (see the header note: draining a whole INTERP-deep
    // queue at ~19 clocks/entry vastly outlasts refilling it), but the
    // count update handles a simultaneous push+pop correctly regardless,
    // rather than assuming it away.
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

    // The next baseband sample is accepted only once the interpolator is
    // idle *and* the queue is empty -- both, not either: idle alone would
    // let a new sample start overwriting queue slots the mixer has not
    // drained yet.
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
