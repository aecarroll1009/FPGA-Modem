// Decimating FIR: folds the filter's linear-phase symmetry to halve the
// multiply count, and decimates by DECIM in the same pass.
//
// The filter is odd-length and symmetric (h[k] == h[N_TAPS-1-k]), so
// h[k]*x[n-k] + h[N_TAPS-1-k]*x[n-(N_TAPS-1-k)] collapses to
// h[k]*(x[n-k] + x[n-(N_TAPS-1-k)]) -- one multiply buys two taps. That
// folding is bit-exact, not an approximation: it only depends on the taps
// being exactly palindromic, which fir_taps_quantized() enforces at
// generation time (see cordic/reference/ddc_reference.py) and
// rx/gen_fir_coef.py checks again before emitting the table. HALF_TAPS
// multiplies replace N_TAPS, at the cost of one MAC step per clock instead
// of all of them at once -- the CORDIC's 19-clock sample spacing leaves
// enough slack for this to be free (see the README's rate budget).
//
// -- delay line -----------------------------------------------------------
// Each rail (I, Q) keeps two mirrored copies of its sample history, so the
// folded sum's two taps can be read in the same cycle without a true
// dual-read-port memory. Depth is the next power of two at or above 2*N_TAPS
// (128 for N_TAPS=63) rather than exactly N_TAPS, so the write pointer can
// never lap a sample the in-flight MAC still needs: a MAC run takes about
// HALF_TAPS clocks, and at most a couple of new samples can land during that
// window at the mixer's 19-clocks-per-sample rate -- far short of even one
// extra pass around a 63-deep buffer, let alone a 128-deep one.
//
// -- decimation -------------------------------------------------------------
// The first output needs N_TAPS accepted samples (matching
// np.convolve(..., 'valid')'s first valid window); every DECIM-th accepted
// sample after that produces the next one. Checked bit-exact against
// fir_decimate() in tb_fir_decimate.sv.
//
// -- accumulation and output ------------------------------------------------
// The accumulator is kept wider than ACC_BITS internally so the exact
// (unsaturated) sum is always available -- matching the reference model's
// int64 accumulation -- and is saturated to ACC_BITS only once, at the end,
// not per MAC step. The output shift is a floor (arithmetic) shift by
// COEF_BITS-1, then a second saturation to OUT_BITS. Neither saturation
// fires at the default widths (the true worst case is about 2^38, inside 40
// bits); they exist so a future width change fails loudly in simulation
// instead of wrapping silently.
//
// Reference model: cordic/reference/ddc_reference.py, fir_decimate().

`timescale 1ns/1ps
`include "fir_coef_table.svh"

module fir_decimate #(
    parameter int IN_BITS  = 17,   // mixer output width (MIX_BITS)
    parameter int DECIM    = 8,
    parameter int ACC_BITS = 40,
    parameter int OUT_BITS = 16
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        in_valid,
    input  logic signed [IN_BITS-1:0]   xi,
    input  logic signed [IN_BITS-1:0]   xq,

    output logic                        out_valid,
    output logic signed [OUT_BITS-1:0]  out_i,
    output logic signed [OUT_BITS-1:0]  out_q
);

    localparam int NTaps    = `FIR_N_TAPS;
    localparam int HalfTaps = `FIR_HALF_TAPS;
    localparam int CoefBits = `FIR_COEF_BITS;
    localparam int KBits    = $clog2(HalfTaps);
    localparam logic [KBits-1:0] CentreIdx = (KBits)'(HalfTaps - 1);

    // NTaps must be odd for "one centre tap, the rest paired" to make sense;
    // gen_fir_coef.py already refuses to emit an even-length table, so this
    // only fires if fir_coef_table.svh is ever hand-edited.
    initial begin
        if (NTaps % 2 == 0)
            $fatal(1, "fir_decimate: NTaps=%0d is even; the folded architecture needs an odd tap count", NTaps);
    end

    // Depth: next power of two at or above 2*NTaps, so address wraparound is
    // a free bitmask (fixed-width unsigned arithmetic) rather than a modulo.
    localparam int Depth = 1 << $clog2(2 * NTaps);
    localparam int AddrW = $clog2(Depth);

    // -- delay line: two mirrored copies per rail --------------------------
    logic signed [IN_BITS-1:0] ram_i_a [0:Depth-1];
    logic signed [IN_BITS-1:0] ram_i_b [0:Depth-1];
    logic signed [IN_BITS-1:0] ram_q_a [0:Depth-1];
    logic signed [IN_BITS-1:0] ram_q_b [0:Depth-1];

    logic [AddrW-1:0] wr_ptr;
    logic [AddrW-1:0] newest_addr;

    always_ff @(posedge clk) begin
        if (in_valid) begin
            ram_i_a[wr_ptr] <= xi;
            ram_i_b[wr_ptr] <= xi;
            ram_q_a[wr_ptr] <= xq;
            ram_q_b[wr_ptr] <= xq;
        end
    end

    // -- fill/decimation counters: when to start a MAC run -----------------
    // filled latches once NTaps samples have ever been accepted; the trigger
    // fires on that same accept (the sample completing the first full
    // window), matching valid convolution's first output. Every DECIM-th
    // accept after that fires again.
    localparam int FillBits = $clog2(NTaps);
    localparam int DecBits  = $clog2(DECIM);

    logic [FillBits-1:0] fill_cnt;
    logic                filled;
    logic [DecBits-1:0]  dec_cnt;
    logic                mac_start;
    logic                will_trigger;

    assign will_trigger = in_valid && (!filled
        ? (fill_cnt == (FillBits)'(NTaps - 1))
        : (dec_cnt  == (DecBits)'(DECIM - 1)));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= '0;
            newest_addr <= '0;
            fill_cnt    <= '0;
            filled      <= 1'b0;
            dec_cnt     <= '0;
            mac_start   <= 1'b0;
        end else begin
            mac_start <= 1'b0;
            if (in_valid) begin
                // synthesis translate_off
                if (will_trigger && mac_state != IDLE)
                    $fatal(1, "fir_decimate: new trigger while a MAC run is still in flight -- the 19-clocks-per-sample rate assumption in the header comment was violated");
                // synthesis translate_on

                newest_addr <= wr_ptr;
                wr_ptr      <= wr_ptr + 1'b1;

                if (!filled) begin
                    if (will_trigger) begin
                        filled    <= 1'b1;
                        dec_cnt   <= '0;
                        mac_start <= 1'b1;
                    end else begin
                        fill_cnt <= fill_cnt + 1'b1;
                    end
                end else begin
                    if (will_trigger) begin
                        dec_cnt   <= '0;
                        mac_start <= 1'b1;
                    end else begin
                        dec_cnt <= dec_cnt + 1'b1;
                    end
                end
            end
        end
    end

    // -- MAC engine ----------------------------------------------------------
    // Two-stage pipeline, address-generate then multiply-accumulate, so the
    // delay line's reads are registered rather than combinational. That is
    // the difference between Quartus mapping ram_i_a/b and ram_q_a/b onto
    // M10K block RAM and it building them out of plain flip-flops with a
    // 128:1 mux in front: the first synthesis pass here (combinational reads)
    // came back at 0 block memory bits, 4630 ALMs, and Fmax nearly halved --
    // the mux was the new critical path. One pipeline stage costs one extra
    // cycle per MAC step, which the 152-clock decimation budget does not
    // notice.
    typedef enum logic [1:0] {IDLE, RUN, FINISH} mac_state_t;
    mac_state_t mac_state;

    // Latched once when the run starts, not read live: newest_addr keeps
    // advancing as new samples are accepted, and at 19 clocks/sample at
    // least one more accept lands during a ~34-cycle run. Addressing off the
    // live register would walk onto a window that shifted mid-computation.
    logic [AddrW-1:0] base_addr;

    // Stage 1: address generation. k walks 0..HalfTaps-1 while `issuing`;
    // once it has issued the centre tap's address, no more are needed.
    logic [KBits-1:0] k;
    logic             issuing;

    logic [AddrW-1:0] addr_a, addr_b;
    // Both wrap naturally: fixed-width unsigned subtraction/addition is
    // modulo 2**AddrW, so order of operations does not matter here.
    assign addr_a = base_addr - (AddrW)'(k);
    assign addr_b = base_addr - (AddrW)'(NTaps - 1) + (AddrW)'(k);

    // Stage 2: the registered read, one cycle behind the address that
    // produced it -- this is what makes the read synchronous. k_d1/mac_valid
    // are k/issuing carried along the same one-cycle delay, so the tap index
    // and coefficient always match the data that just arrived.
    logic signed [IN_BITS-1:0] rd_i_a, rd_i_b, rd_q_a, rd_q_b;
    logic [KBits-1:0] k_d1;
    logic             mac_valid;

    always_ff @(posedge clk) begin
        rd_i_a <= ram_i_a[addr_a];
        rd_i_b <= ram_i_b[addr_b];
        rd_q_a <= ram_q_a[addr_a];
        rd_q_b <= ram_q_b[addr_b];
    end

    logic is_centre_d1;
    assign is_centre_d1 = (k_d1 == CentreIdx);

    // One guard bit for the pre-add: two IN_BITS values summing can exceed
    // IN_BITS by exactly one bit. The centre tap uses rd_*_a alone -- doubling
    // it would count that sample twice, since addr_b equals addr_a there.
    logic signed [IN_BITS:0] term_i, term_q;
    assign term_i = is_centre_d1
        ? {rd_i_a[IN_BITS-1], rd_i_a}
        : ({rd_i_a[IN_BITS-1], rd_i_a} + {rd_i_b[IN_BITS-1], rd_i_b});
    assign term_q = is_centre_d1
        ? {rd_q_a[IN_BITS-1], rd_q_a}
        : ({rd_q_a[IN_BITS-1], rd_q_a} + {rd_q_b[IN_BITS-1], rd_q_b});

    logic signed [CoefBits-1:0] coef_k_d1;
    assign coef_k_d1 = FIR_COEF[k_d1];

    // Declared at the product's true full width (CoefBits + (IN_BITS+1)) and
    // computed by a plain assignment, not a sizing cast: `Wide'(a*b)` would
    // evaluate a*b in the self-determined width of its narrower operands
    // first and only extend the (already truncated) result afterward, which
    // silently discards the product's high bits. A declared wire of the
    // right width gives the multiply its context directly.
    localparam int ProdBits = CoefBits + IN_BITS + 1;
    logic signed [ProdBits-1:0] prod_i, prod_q;
    assign prod_i = coef_k_d1 * term_i;
    assign prod_q = coef_k_d1 * term_q;

    // Wide enough that the exact HALF_TAPS-term sum can never wrap this
    // register, even for a pathological all-same-sign, full-scale input --
    // see the header note on where the one-time ACC_BITS saturation happens.
    localparam int WideAcc = ACC_BITS + 8;
    logic signed [WideAcc-1:0] acc_i, acc_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_state <= IDLE;
            k         <= '0;
            issuing   <= 1'b0;
            k_d1      <= '0;
            mac_valid <= 1'b0;
            base_addr <= '0;
            acc_i     <= '0;
            acc_q     <= '0;
            out_valid <= 1'b0;
            out_i     <= '0;
            out_q     <= '0;
        end else begin
            out_valid <= 1'b0;
            case (mac_state)
                IDLE: begin
                    if (mac_start) begin
                        k         <= '0;
                        issuing   <= 1'b1;
                        mac_valid <= 1'b0;
                        acc_i     <= '0;
                        acc_q     <= '0;
                        base_addr <= newest_addr;
                        mac_state <= RUN;
                    end
                end
                RUN: begin
                    // Stage 1: advance the address generator.
                    k_d1      <= k;
                    mac_valid <= issuing;
                    if (issuing) begin
                        if (k == CentreIdx) issuing <= 1'b0;   // just issued the last address
                        else                k <= k + 1'b1;
                    end

                    // Stage 2: accumulate the data that arrived from last
                    // cycle's address. Finishing is keyed off k_d1, the index
                    // whose contribution this cycle just added in.
                    if (mac_valid) begin
                        acc_i <= acc_i + WideAcc'(prod_i);
                        acc_q <= acc_q + WideAcc'(prod_q);
                        if (is_centre_d1) mac_state <= FINISH;
                    end
                end
                FINISH: begin
                    out_i     <= sat_shift(acc_i);
                    out_q     <= sat_shift(acc_q);
                    out_valid <= 1'b1;
                    mac_state <= IDLE;
                end
                default: mac_state <= IDLE;
            endcase
        end
    end

    // Saturate the exact wide sum to ACC_BITS, shift right (floor) by
    // COEF_BITS-1, then saturate to OUT_BITS -- the same two-stage
    // saturation as fir_decimate()'s acc_i/acc_q -> yi/yq path.
    localparam logic signed [WideAcc-1:0] AccMax = WideAcc'((1 <<< (ACC_BITS-1)) - 1);
    localparam logic signed [WideAcc-1:0] AccMin = WideAcc'(-(1 <<< (ACC_BITS-1)));
    localparam logic signed [WideAcc-1:0] OutMax  = WideAcc'((1 <<< (OUT_BITS-1)) - 1);
    localparam logic signed [WideAcc-1:0] OutMin  = WideAcc'(-(1 <<< (OUT_BITS-1)));

    function automatic logic signed [OUT_BITS-1:0] sat_shift(
        input logic signed [WideAcc-1:0] acc
    );
        logic signed [WideAcc-1:0] acc_sat, shifted;

        if (acc > AccMax)      acc_sat = AccMax;
        else if (acc < AccMin) acc_sat = AccMin;
        else                   acc_sat = acc;

        shifted = acc_sat >>> (CoefBits - 1);

        if (shifted > OutMax)      sat_shift = OutMax[OUT_BITS-1:0];
        else if (shifted < OutMin) sat_shift = OutMin[OUT_BITS-1:0];
        else                       sat_shift = shifted[OUT_BITS-1:0];
    endfunction

endmodule
