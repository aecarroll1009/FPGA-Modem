// SPI master for the DE1-SoC's on-board LTC2308 ADC, using the short-CONVST-
// pulse protocol in datasheet Figure 9.
// Samples at 400 kS/s rather than the datasheet's 500 kS/s ceiling, to clear
// tCONV's guaranteed maximum (1.6us) with margin inside one 50 MHz clock
// domain.
// Outputs sample_code as straight binary in unipolar mode, with
// sample_valid pulsing once per completed conversion.

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

    // Config word (S/D O/S S1 S0 UNI SLP): CH0 single-ended, unipolar, no
    // sleep -- SLP=1's 200ms wake time would stall a streaming ADC.
    localparam logic [5:0] DinWord = 6'b100010;

    // -- cycle budget, all in 20ns (50 MHz) clocks --------------------------
    localparam int Period     = 125;  // 50e6 / 400e3: the sample period
    localparam int ConvstHigh = 2;    // 40ns >= tWHCONV (20ns min)
    // cnt=0 is the first clock, so ShiftBegin=80 is reached after 81 clocks
    // (1.62us) since CONVST rose -- past tCONV's guaranteed max of 1.6us.
    localparam int ShiftBegin = 80;
    localparam int NPulses    = 12;
    localparam int ShiftEnd   = ShiftBegin + 1 + 2 * NPulses - 1;  // 104
    localparam int EmitCycle  = ShiftEnd + 1;                      // 105

    // Cycles [EmitCycle+1, Period-1] (106..124) are idle margin for
    // tHCONVST, tWLCONVST, and tACQ, all cleared past their datasheet minimums.
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

    // DIN bit k is presented one full clock before pulse k's rising edge
    // (setup margin), not changed on the edge that samples it.
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
            // Reset lands on the last cycle of a period so adc_convst comes
            // out of reset low, with the first real CONVST pulse starting
            // clean one clock later.
            cnt          <= CntBits'(Period - 1);
            code_reg     <= '0;
            first_done   <= 1'b0;
            sample_valid <= 1'b0;
            sample_code  <= '0;
        end else begin
            cnt          <= (cnt == CntBits'(Period - 1)) ? '0 : cnt + 1'b1;
            sample_valid <= 1'b0;

            // MSB (B11) is already valid at ShiftBegin, before any SCK pulse.
            if (cnt == CntBits'(ShiftBegin))
                code_reg[11] <= adc_dout;
            else if (in_shift && pulse_half && pulse_idx <= 4'd10)
                // One clock after pulse p's falling edge: yields B(10-p).
                // p=11's low half is Hi-Z and is skipped.
                code_reg[10 - pulse_idx] <= adc_dout;

            if (cnt == CntBits'(EmitCycle)) begin
                // The first conversion completed before any DIN config word
                // was sent, so it isn't CH0/unipolar; sample_valid is held
                // low for it and asserted from the second conversion on.
                sample_code  <= code_reg;
                sample_valid <= first_done;
                first_done   <= 1'b1;
            end
        end
    end

endmodule
