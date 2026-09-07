// Shared output stage for the decimating and interpolating FIRs.
//
// Saturates the accumulator to ACC_BITS, shifts right (floor) by
// COEF_BITS-1, then saturates to SatOutBits, matching the reference model.
// The includer must define WideAcc, ACC_BITS, CoefBits, and SatOutBits.

`ifndef FIR_SAT_SHIFT_SVH
`define FIR_SAT_SHIFT_SVH

localparam logic signed [WideAcc-1:0] AccMax = WideAcc'((1 <<< (ACC_BITS-1)) - 1);
localparam logic signed [WideAcc-1:0] AccMin = WideAcc'(-(1 <<< (ACC_BITS-1)));
localparam logic signed [WideAcc-1:0] OutMax = WideAcc'((1 <<< (SatOutBits-1)) - 1);
localparam logic signed [WideAcc-1:0] OutMin = WideAcc'(-(1 <<< (SatOutBits-1)));

function automatic logic signed [SatOutBits-1:0] sat_shift(
    input logic signed [WideAcc-1:0] acc
);
    logic signed [WideAcc-1:0] acc_sat, shifted;

    if (acc > AccMax)      acc_sat = AccMax;
    else if (acc < AccMin) acc_sat = AccMin;
    else                   acc_sat = acc;

    shifted = acc_sat >>> (CoefBits - 1);

    if (shifted > OutMax)      sat_shift = OutMax[SatOutBits-1:0];
    else if (shifted < OutMin) sat_shift = OutMin[SatOutBits-1:0];
    else                       sat_shift = shifted[SatOutBits-1:0];
endfunction

`endif
