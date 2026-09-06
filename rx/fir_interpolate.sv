// Interpolating FIR: the TX-side counterpart to fir_decimate.sv, upsampling
// baseband IQ by INTERP ahead of the up-convert mixer.
//
// Realized as a polyphase filter, not literal zero-stuffing: phase p's
// output is sum_k FIR_INTERP_COEF[p + k*INTERP] * x[n-k], run directly
// against the un-stuffed input history. This is exactly equal to
// zero-stuffing then filtering, not an approximation of it -- INTERP-1 out
// of every INTERP terms in the zero-stuffed sum multiply a known zero, and
// skipping them changes nothing about the result (see polyphase_decompose()
// in cordic/reference/ddc_reference.py, and fir_interpolate() there for the
// zero-stuffed reference this is checked bit-exact against).
//
// -- why this needs no fold, and no addressed RAM -------------------------
// The decimator folds its 63 taps around their linear-phase symmetry and
// needs a 128-deep circular buffer per rail, because a new sample can land
// mid-computation (it runs continuously at the mixer's 19-clocks-per-sample
// rate). Neither pressure applies here: this filter's coefficients are not
// symmetric within a phase (a phase is an arbitrary sub-sampling of the
// taps, not a mirror pair), and in_ready is deliberately not asserted again
// until all INTERP phases for the current sample have been produced, so no
// new sample can ever arrive mid-computation -- there is no race to guard
// against. That also means the history only needs to hold the longest
// phase's reach (FIR_INTERP_MAX_PHASE_LEN samples, 8 by default), so it is a
// plain shift register, not an addressed circular buffer: hist_i[k] is
// x[n-k] directly, with no address arithmetic to get wrong.
//
// -- coefficients -----------------------------------------------------------
// FIR_INTERP_COEF is flat (not folded) and FIR_INTERP_PHASE_LEN[p] gives
// each phase's tap count directly, since N_TAPS is not a multiple of INTERP
// in general (63/8 leaves one phase with 7 taps instead of 8) -- see
// rx/gen_fir_coef.py.
//
// -- reset ------------------------------------------------------------------
// The history shift register is explicitly reset to zero, not left as X:
// unlike fir_decimate, this filter produces output from the very first
// accepted sample, using whatever history exists so far -- there is no
// window-fill period to wait out first (see fir_interpolate()'s docstring).
// That only matches the reference model if "no history yet" reads as zero
// on both sides.

`timescale 1ns/1ps
`include "fir_interp_coef_table.svh"

module fir_interpolate #(
    parameter int DATA_BITS = 16,   // in/out width, both sides of interpolation
    parameter int ACC_BITS  = 40
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        in_valid,
    input  logic signed [DATA_BITS-1:0] xi,
    input  logic signed [DATA_BITS-1:0] xq,
    output logic                        in_ready,

    output logic                        out_valid,
    output logic signed [DATA_BITS-1:0] out_i,
    output logic signed [DATA_BITS-1:0] out_q
);

    localparam int Interp   = `FIR_INTERP_L;
    localparam int NTaps    = `FIR_INTERP_N_TAPS;
    localparam int CoefBits = `FIR_INTERP_COEF_BITS;
    localparam int MaxLen   = `FIR_INTERP_MAX_PHASE_LEN;

    localparam int PBits = $clog2(Interp);
    localparam int KBits = $clog2(MaxLen);
    localparam int AddrW = $clog2(NTaps);

    typedef enum logic [1:0] {IDLE, RUN, FINISH} state_t;
    state_t state;

    assign in_ready = (state == IDLE);
    wire accept = in_valid && in_ready;

    // -- history: a plain shift register, not an addressed buffer ----------
    // hist_i[0]/hist_q[0] is x[n] (newest), hist_i[MaxLen-1] is x[n-MaxLen+1].
    logic signed [DATA_BITS-1:0] hist_i [0:MaxLen-1];
    logic signed [DATA_BITS-1:0] hist_q [0:MaxLen-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MaxLen; i++) begin
                hist_i[i] <= '0;
                hist_q[i] <= '0;
            end
        end else if (accept) begin
            hist_i[0] <= xi;
            hist_q[0] <= xq;
            for (int i = 1; i < MaxLen; i++) begin
                hist_i[i] <= hist_i[i-1];
                hist_q[i] <= hist_q[i-1];
            end
        end
    end

    // -- phase/tap counters --------------------------------------------------
    logic [PBits-1:0] p;   // which of the INTERP output phases is running
    logic [KBits-1:0] k;   // tap index within phase p

    logic [31:0] phase_len;   // int in the generated header; taken as-is
    assign phase_len = FIR_INTERP_PHASE_LEN[p];
    wire last_tap = (32'(k) == phase_len - 1);
    wire last_phase = (p == PBits'(Interp - 1));

    logic [AddrW-1:0] coef_addr;
    assign coef_addr = AddrW'(p) + AddrW'(k) * AddrW'(Interp);

    logic signed [CoefBits-1:0] coef_val;
    assign coef_val = FIR_INTERP_COEF[coef_addr];

    logic signed [DATA_BITS-1:0] tap_i, tap_q;
    assign tap_i = hist_i[k];
    assign tap_q = hist_q[k];

    // Declared at the product's true width and computed by a plain
    // assignment, not a sizing cast -- see fir_decimate.sv's header for why
    // `Wide'(a*b)` truncates the product before extending it.
    localparam int ProdBits = CoefBits + DATA_BITS;
    logic signed [ProdBits-1:0] prod_i, prod_q;
    assign prod_i = coef_val * tap_i;
    assign prod_q = coef_val * tap_q;

    localparam int WideAcc = ACC_BITS + 8;
    logic signed [WideAcc-1:0] acc_i, acc_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            p         <= '0;
            k         <= '0;
            acc_i     <= '0;
            acc_q     <= '0;
            out_valid <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
        end else begin
            out_valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (accept) begin
                        p     <= '0;
                        k     <= '0;
                        acc_i <= '0;
                        acc_q <= '0;
                        state <= RUN;
                    end
                end
                RUN: begin
                    acc_i <= acc_i + WideAcc'(prod_i);
                    acc_q <= acc_q + WideAcc'(prod_q);
                    if (last_tap) begin
                        state <= FINISH;
                    end else begin
                        k <= k + 1'b1;
                    end
                end
                FINISH: begin
                    out_i     <= sat_shift(acc_i);
                    out_q     <= sat_shift(acc_q);
                    out_valid <= 1'b1;
                    if (last_phase) begin
                        state <= IDLE;
                    end else begin
                        p     <= p + 1'b1;
                        k     <= '0;
                        acc_i <= '0;
                        acc_q <= '0;
                        state <= RUN;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

    // Saturate the exact wide sum to ACC_BITS, shift right (floor) by
    // COEF_BITS-1, then saturate to OUT_BITS (= DATA_BITS here) -- the same
    // two-stage saturation as fir_decimate()'s and fir_interpolate()'s
    // acc -> y path in the reference model.
    localparam logic signed [WideAcc-1:0] AccMax = WideAcc'((1 <<< (ACC_BITS-1)) - 1);
    localparam logic signed [WideAcc-1:0] AccMin = WideAcc'(-(1 <<< (ACC_BITS-1)));
    localparam logic signed [WideAcc-1:0] OutMax  = WideAcc'((1 <<< (DATA_BITS-1)) - 1);
    localparam logic signed [WideAcc-1:0] OutMin  = WideAcc'(-(1 <<< (DATA_BITS-1)));

    function automatic logic signed [DATA_BITS-1:0] sat_shift(
        input logic signed [WideAcc-1:0] acc
    );
        logic signed [WideAcc-1:0] acc_sat, shifted;

        if (acc > AccMax)      acc_sat = AccMax;
        else if (acc < AccMin) acc_sat = AccMin;
        else                   acc_sat = acc;

        shifted = acc_sat >>> (CoefBits - 1);

        if (shifted > OutMax)      sat_shift = OutMax[DATA_BITS-1:0];
        else if (shifted < OutMin) sat_shift = OutMin[DATA_BITS-1:0];
        else                       sat_shift = shifted[DATA_BITS-1:0];
    endfunction

endmodule
