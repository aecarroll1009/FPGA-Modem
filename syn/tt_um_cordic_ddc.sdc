# Timing constraints for the TinyTapeout wrapper.
#
# Same 20 ns target as rx_top.sdc, for a different reason: TinyTapeout supplies
# a nominal 50 MHz user clock. The serialised wrapper spends 22 clocks per
# sample rather than the core's 19, so 50 MHz here is 2.27 MS/s.
#
# This build is an FPGA proxy for an ASIC target, so read it as a relative
# measurement, not an absolute one. ALMs are LUT-based and do not predict
# standard-cell area -- the CORDIC's barrel shifters in particular are cheap in
# LUTs and expensive in cells. What it does check is that the wrapper's control
# logic closes timing and infers no memory or multipliers it did not ask for.

create_clock -name clk -period 20.000 [get_ports clk]

derive_clock_uncertainty

# Asynchronous, held for many cycles at power-up.
set_false_path -from [get_ports rst_n]

# ena is a chip-select from the TinyTapeout harness, static for the life of a
# run, and this design does not gate on it.
set_false_path -from [get_ports ena]

# The byte-serial pins are driven by an off-chip host whose timing is not
# characterised here; constraining them to invented numbers would manufacture
# false failures. The real budget arrives with the host interface.
set_false_path -from [get_ports {ui_in[*] uio_in[*]}]
set_false_path -to   [get_ports {uo_out[*] uio_out[*] uio_oe[*]}]
