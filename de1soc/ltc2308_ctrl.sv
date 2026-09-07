// SPI master for the DE1-SoC's on-board LTC2308 ADC.
//
// Runs the converter at 400 kS/s, not its advertised 500 kS/s ceiling. The
// 500 kS/s number only closes against the LTC2308's *typical* conversion
// time (tCONV = 1.3us); the datasheet's guaranteed maximum is 1.6us, and
// this design waits out the full maximum rather than gambling on a typical
// part. A 2.5us sample period (400 kS/s) leaves that guaranteed-complete
// wait plus a comfortable SPI shift-out window inside a single 50 MHz clock
// domain, with no PLL needed. See ddc_reference.py's DDCConfig docstring for
// the same reasoning on the reference-model side.
//
// -- protocol (LTC2308 datasheet Figure 9, "short CONVST pulse") ----------
// One period: CONVST pulses high, then low; the ADC starts converting on
// the rising edge. After waiting out tCONV, this master drives 12 SCK
// pulses. The MSB (B11) is already valid before the first pulse -- read
// directly, no clock needed -- and each pulse's *falling* edge exposes the
// next bit (B10 down to B0), 11 more bits from 11 of the 12 pulses; the
// 12th pulse's fall returns the bus to Hi-Z and carries no new bit. Each
// bit is captured one full clock after the falling edge that exposes it
// (not on that same edge), which is what turns tdDO's up-to-12.5ns
// propagation delay into a full 20ns of margin instead of a race.
//
// The same 12 SCK pulses also load a 6-bit configuration word (S/D, O/S,
// S1, S0, UNI, SLP) on their first 6 *rising* edges, which is what the
// LTC2308 will use for the *next* conversion, not this one -- "between
// conversions... data from the previous conversion is shifted out on SDO"
// (Overview, LTC2308 datasheet). This master always sends the same word
// (channel 0, single-ended, unipolar, no sleep), so from the second sample
// onward every code is CH0/unipolar; only the very first code after reset
// was converted before any configuration word was ever sent and must be
// discarded -- sample_valid stays low for it.
//
// DIN changes a full clock *before* the SCK rising edge that samples it
// (during the low half preceding each pulse, not the high half coincident
// with it), the mirror image of the SDO timing above: the ADC needs SDI
// set up ahead of the edge it latches on, not merely stable by that edge.
//
// Unipolar mode requires COM biased to REFCOMP/2 (datasheet Figure 2), and
// the DE1-SoC's 2x5 header brings out only VCC5/ADC_IN0-7/GND -- COM is
// grounded on-board, so bipolar mode is not reachable here and the analog
// input must be biased to mid-scale externally. sample_code is therefore
// straight binary, unsigned, not two's complement.

`timescale 1ns/1ps

module ltc2308_ctrl (
    input  logic        clk,        // 50 MHz (DE1-SoC's CLOCK_50)
    input  logic        rst_n,

    output logic        adc_convst,
    output logic        adc_sclk,
    output logic        adc_din,    // to the ADC's SDI
    input  logic        adc_dout,   // from the ADC's SDO

    output logic        sample_valid,   // one-cycle pulse, ~every 125 clocks
    output logic [11:0] sample_code     // straight binary, valid with sample_valid
);

    // Channel 0, single-ended, unipolar, no sleep -- S/D O/S S1 S0 UNI SLP.
    // Table 1 (Channel Configuration): S/D=1,O/S=0,S1=0,S0=0 selects CH0
    // single-ended ("+" vs COM "-"); UNI=1 selects unipolar; SLP=0 keeps the
    // reference alive between conversions (SLP=1's 200ms wake time would be
    // fatal to a streaming ADC).
    localparam logic [5:0] DinWord = 6'b100010;

    // -- cycle budget, all in 20ns (50 MHz) clocks --------------------------
    localparam int Period     = 125;  // 50e6 / 400e3: the sample period
    localparam int ConvstHigh = 2;    // 40ns >= tWHCONV (20ns min)
    // cnt reaches ShiftBegin after 81 clocks (1.62us) since CONVST rose, not
    // 80 (1.6us) -- cnt is 0 for the first clock, so the Nth value is reached
    // on the (N+1)th edge. 1.62us still clears tCONV's guaranteed maximum of
    // 1.6us, with 20ns to spare.
    localparam int ShiftBegin = 80;
    localparam int NPulses    = 12;
    localparam int ShiftEnd   = ShiftBegin + 1 + 2 * NPulses - 1;  // 104
    localparam int EmitCycle  = ShiftEnd + 1;                      // 105

    // Cycles [EmitCycle+1, Period-1] (106..124, 380ns) are deliberately idle:
    // margin for tHCONVST (>=20ns after the last SCK fall) and tWLCONVST
    // (>=410ns CONVST-low during the transfer), both cleared by a wide
    // margin rather than to the datasheet minimum. tACQ (>=240ns, measured
    // from the 7th SCK rising edge to the *next* CONVST rise) spans this
    // idle window too: pulse 7's rising edge is at cnt=93, the next CONVST
    // rise is at cnt=Period(125 -> wraps to 0), a 640ns gap -- 2.7x tACQ's
    // minimum.
    localparam int CntBits = $clog2(Period);
    logic [CntBits-1:0] cnt;

    // -- combinational decode of where `cnt` sits in a shift pulse ----------
    logic       in_shift;
    logic [4:0] shift_idx;   // 0..23 across the 12 pulses' high/low halves
    logic [3:0] pulse_idx;   // 0..11
    logic       pulse_half;  // 0 = high (rising-edge instant), 1 = low (falling)

    assign in_shift  = (cnt > CntBits'(ShiftBegin)) && (cnt <= CntBits'(ShiftEnd));
    assign shift_idx = 5'(cnt - CntBits'(ShiftBegin + 1));
    assign pulse_idx = shift_idx[4:1];
    assign pulse_half = shift_idx[0];

    assign adc_convst = (cnt < CntBits'(ConvstHigh));
    assign adc_sclk   = in_shift && !pulse_half;

    // DIN bit k (k=0..5) is presented starting at cnt=ShiftBegin+2k -- one
    // full clock before pulse k's own rising edge at ShiftBegin+2k+1 -- and
    // held through that rising-edge cycle, giving the ADC a full 20ns of
    // setup rather than changing SDI on the very edge that samples it.
    logic [CntBits-1:0] din_offset;
    logic [2:0]         din_idx;
    logic               din_in_range;

    assign din_in_range = (cnt >= CntBits'(ShiftBegin)) && (cnt <= CntBits'(ShiftBegin + 2 * 6 - 1));
    assign din_offset   = cnt - CntBits'(ShiftBegin);
    assign din_idx      = 3'(din_offset >> 1);
    assign adc_din      = din_in_range ? DinWord[5 - din_idx] : 1'b0;

    logic [11:0] code_reg;
    logic        first_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset lands on the last cycle of a period, not cycle 0, so
            // adc_convst comes out of reset LOW and its first real
            // conversion begins with a clean, unambiguous rising edge one
            // clock later -- resetting straight to cycle 0 would leave
            // CONVST already asserted (cnt < ConvstHigh is true at 0),
            // indistinguishable from a pulse already in progress.
            cnt          <= CntBits'(Period - 1);
            code_reg     <= '0;
            first_done   <= 1'b0;
            sample_valid <= 1'b0;
            sample_code  <= '0;
        end else begin
            cnt          <= (cnt == CntBits'(Period - 1)) ? '0 : cnt + 1'b1;
            sample_valid <= 1'b0;

            // The pre-pulse MSB: stable well before this point (the whole
            // ShiftBegin wait exists to guarantee that), so a plain sample
            // here carries none of the falling-edge timing concerns below.
            if (cnt == CntBits'(ShiftBegin))
                code_reg[11] <= adc_dout;
            else if (in_shift && pulse_half && pulse_idx <= 4'd10)
                // One clock after pulse p's falling edge, per the header
                // comment: yields B(10-p) for p=0..10, i.e. B10 down to B0.
                // p=11's low half is the bus going Hi-Z and is skipped.
                code_reg[10 - pulse_idx] <= adc_dout;

            if (cnt == CntBits'(EmitCycle)) begin
                sample_code  <= code_reg;
                sample_valid <= first_done;
                first_done   <= 1'b1;
            end
        end
    end

endmodule
