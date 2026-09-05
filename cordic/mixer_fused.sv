// Fused mixer: rotates each input sample by +/-theta directly, using the
// shared CORDIC core as both the rotator and the mix. No discrete complex
// multiplier -- prerotate_conj() handles the quadrant's 90-degree part with
// sign swaps only, and the CORDIC's rotation handles the residual.
//
// DOWNCONVERT selects the rotation direction, so RX and TX share this one
// module instead of two near-duplicates: 1 rotates by -theta (down-convert,
// mix with the NCO's conjugate), 0 rotates by +theta (up-convert). The two
// cases differ only in sign -- rotating by +theta is the same computation as
// rotating by -theta with the quadrant negated mod 4, so eff_quadrant folds
// the direction into the existing case table rather than duplicating it.
//
// The CORDIC's output carries the gain K (~1.6467); that is removed later,
// in the decimating/interpolating filter's coefficients, not here.
//
// in_valid is ignored while busy is high -- the caller must wait for busy
// to fall before asserting the next sample. xi, xq, quadrant, and residual
// are latched the instant a sample is accepted, so none of them need to
// stay stable beyond that one cycle.
//
// Reference model (DOWNCONVERT=1 only -- the up-convert path has no
// reference model yet): cordic/reference/ddc_reference.py, DDC.mix_fused().

`timescale 1ns/1ps

module mixer_fused #(
    parameter int DATA_BITS   = 16,
    parameter int CORDIC_BITS = 20,
    parameter int MIX_BITS    = 17,
    parameter int ANG_BITS    = 18,
    parameter bit DOWNCONVERT = 1'b1
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        in_valid,
    input  logic signed [DATA_BITS-1:0] xi,
    input  logic signed [DATA_BITS-1:0] xq,
    input  logic [1:0]                  quadrant,
    input  logic [ANG_BITS-3:0]         residual,

    output logic                        busy,
    output logic                        out_valid,
    output logic signed [MIX_BITS-1:0]  mix_i,
    output logic signed [MIX_BITS-1:0]  mix_q
);

    // One guard bit is spent leaving headroom for the K growth (K > 1); the
    // rest widen data_bits up to the CORDIC's own datapath width.
    //
    // That headroom is against the complex envelope, not the per-axis word.
    // The rotation grows |v| monotonically to K*|v|, so it stays exact only
    // while |xi + j*xq| <= (2**(CORDIC_BITS-1) - 1) / (K * 2**Guard), which at
    // the default widths is ~1.21x full scale. A rotating tone sits at 1.0x
    // and is safe; arbitrary IQ reaches sqrt(2) ~= 1.41x and clips inside the
    // CORDIC's sat_add/sat_sub. That clipping is bit-exact against the
    // reference model, so it is a backoff budget to respect, not a mismatch.
    localparam int Guard        = CORDIC_BITS - DATA_BITS - 1;
    localparam int ResidualBits = ANG_BITS - 2;

    // -- prerotate_conj: multiply (xi + j*xq) by exp(-j*eff_quadrant*pi/2) --
    // DOWNCONVERT=1 uses quadrant as-is (exp(-j*quadrant*pi/2)); DOWNCONVERT=0
    // negates it mod 4, which is exp(+j*quadrant*pi/2) -- the up-conversion
    // rotation -- computed by the same case table.
    logic [1:0] eff_quadrant;
    assign eff_quadrant = DOWNCONVERT ? quadrant : (2'd0 - quadrant);

    logic signed [DATA_BITS-1:0] ri, rq;
    always_comb begin
        unique case (eff_quadrant)
            2'd0: begin ri = xi;    rq = xq;   end
            2'd1: begin ri = xq;    rq = -xi;  end
            2'd2: begin ri = -xi;   rq = -xq;  end
            default: begin ri = -xq; rq = xi;  end // 2'd3
        endcase
    end

    // Sign-extend to the CORDIC's full width *before* shifting, so the
    // shift only discards redundant sign-replica bits, not real ones -- a
    // shift confined to a (Guard + DATA_BITS)-bit intermediate would instead
    // truncate the top of the result.
    logic signed [CORDIC_BITS-1:0] ri_ext, rq_ext;
    assign ri_ext = {{(CORDIC_BITS-DATA_BITS){ri[DATA_BITS-1]}}, ri};
    assign rq_ext = {{(CORDIC_BITS-DATA_BITS){rq[DATA_BITS-1]}}, rq};

    logic signed [CORDIC_BITS-1:0] x0_comb, y0_comb;
    logic signed [ANG_BITS-1:0]    z0_comb;
    logic signed [ANG_BITS-1:0]    residual_ext;
    assign x0_comb = ri_ext <<< Guard;
    assign y0_comb = rq_ext <<< Guard;
    assign residual_ext = {{(ANG_BITS-ResidualBits){1'b0}}, residual};
    // z0 = -residual to down-convert, +residual to up-convert.
    assign z0_comb = DOWNCONVERT ? -residual_ext : residual_ext;

    // -- accept: latch the CORDIC's operands the cycle the sample lands ----
    logic signed [CORDIC_BITS-1:0] x0_reg, y0_reg;
    logic signed [ANG_BITS-1:0]    z0_reg;

    typedef enum logic [1:0] {IDLE, WAIT_BUSY, RUN} state_t;
    state_t state;

    logic start;
    logic cordic_busy, cordic_done;
    logic signed [CORDIC_BITS-1:0] x_out, y_out;
    logic signed [ANG_BITS-1:0]    z_out_unused;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            start <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (in_valid) begin
                        x0_reg <= x0_comb;
                        y0_reg <= y0_comb;
                        z0_reg <= z0_comb;
                        start  <= 1'b1;
                        state  <= WAIT_BUSY;
                    end
                end
                WAIT_BUSY: begin
                    if (cordic_busy) begin
                        start <= 1'b0;
                        state <= RUN;
                    end
                end
                RUN: begin
                    if (cordic_done) state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    assign busy = (state != IDLE);

    cordic_core #(.WIDTH(CORDIC_BITS)) u_cordic (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (start),
        .x_in   (x0_reg),
        .y_in   (y0_reg),
        .z_in   (z0_reg),
        .busy   (cordic_busy),
        .done   (cordic_done),
        .x_out  (x_out),
        .y_out  (y_out),
        .z_out  (z_out_unused)
    );

    // -- shift back down by Guard bits and saturate to MIX_BITS ------------
    // Same wide-compare-then-slice shape as cordic_core's sat_add/sat_sub.
    function automatic logic signed [MIX_BITS-1:0] sat_mix(
        input logic signed [CORDIC_BITS-1:0] v
    );
        logic signed [CORDIC_BITS-1:0] shifted, max_val, min_val;
        shifted = v >>> Guard;
        max_val = (1 <<< (MIX_BITS-1)) - 1;
        min_val = -(1 <<< (MIX_BITS-1));
        if (shifted > max_val)      sat_mix = max_val[MIX_BITS-1:0];
        else if (shifted < min_val) sat_mix = min_val[MIX_BITS-1:0];
        else                        sat_mix = shifted[MIX_BITS-1:0];
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            mix_i     <= '0;
            mix_q     <= '0;
        end else begin
            out_valid <= (state == RUN) && cordic_done;
            if ((state == RUN) && cordic_done) begin
                mix_i <= sat_mix(x_out);
                mix_q <= sat_mix(y_out);
            end
        end
    end

endmodule
