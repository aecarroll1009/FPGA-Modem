// Decimating FIR: folds the filter's linear-phase symmetry (h[k] ==
// h[N_TAPS-1-k]) to halve the multiply count, and decimates by DECIM in the
// same pass.
//
// Two mirrored copies of each rail's sample history let the folded sum's two
// taps be read in the same cycle without a true dual-read-port memory, and a
// two-stage address-generate/multiply-accumulate pipeline produces one
// output every DECIM accepted samples.
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
    // filled latches once NTaps samples have been accepted; the trigger
    // fires on that accept (matching valid convolution's first window), then
    // every DECIM-th accept after that.
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
                    $fatal(1, "fir_decimate: new trigger while a MAC run is still in flight");
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
    // Two-stage pipeline (address-generate, then multiply-accumulate) so the
    // delay-line reads are registered, not combinational -- required for
    // Quartus to map the RAMs onto M10K block RAM instead of flip-flops.
    typedef enum logic [1:0] {IDLE, RUN, FINISH} mac_state_t;
    mac_state_t mac_state;

    // Latched once when the run starts, not read live: newest_addr keeps
    // advancing as new samples arrive during the run, and addressing off the
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
    // produced it. k_d1/mac_valid carry k/issuing along the same delay, so
    // the tap index and coefficient match the data that just arrived.
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

    // Folded pair: h[k]*(x[n-k] + x[n-(N-1-k)]) replaces two separate
    // multiplies, valid because the taps are exactly symmetric (enforced
    // when fir_coef_table.svh is generated). One guard bit covers the
    // pre-add headroom; the centre tap uses rd_*_a alone, since addr_b
    // equals addr_a there and doubling it would count the sample twice.
    logic signed [IN_BITS:0] term_i, term_q;
    assign term_i = is_centre_d1
        ? {rd_i_a[IN_BITS-1], rd_i_a}
        : ({rd_i_a[IN_BITS-1], rd_i_a} + {rd_i_b[IN_BITS-1], rd_i_b});
    assign term_q = is_centre_d1
        ? {rd_q_a[IN_BITS-1], rd_q_a}
        : ({rd_q_a[IN_BITS-1], rd_q_a} + {rd_q_b[IN_BITS-1], rd_q_b});

    logic signed [CoefBits-1:0] coef_k_d1;
    assign coef_k_d1 = FIR_COEF[k_d1];

    // Declared at the product's true width (CoefBits + IN_BITS + 1) and
    // computed by plain assignment, not `Wide'(a*b)`: that cast would
    // evaluate a*b at the narrower operand width first, silently discarding
    // the product's high bits before extending.
    localparam int ProdBits = CoefBits + IN_BITS + 1;
    logic signed [ProdBits-1:0] prod_i, prod_q;
    assign prod_i = coef_k_d1 * term_i;
    assign prod_q = coef_k_d1 * term_q;

    // Worst case: |coefficient| x 2 (each non-centre tap sums two folded
    // samples) x full-scale input, summed over the real coefficient table,
    // bounds the exact sum at about 2^30.6 -- comfortably inside ACC_BITS=40
    // itself, let alone this ACC_BITS+8 register, so the sum never wraps
    // before the one-time saturation in sat_shift() below.
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
