# Timing constraints for rx_top.
#
# 50 MHz is the DE1-SoC's stock oscillator, so it is the number every build
# closes against. It is no longer a floor: the iterative CORDIC needs 19
# clocks per sample and the board's LTC2308 tops out at 500 kS/s, so the
# datapath only *requires* 9.5 MHz. Constraining at 50 MHz anyway keeps this
# an honest Fmax measurement -- the reported slack is headroom against the
# real oscillator, not against a rate the converter cannot reach.

create_clock -name clk -period 20.000 [get_ports clk]

derive_clock_uncertainty

# Asynchronous, held for many cycles at power-up.
set_false_path -from [get_ports rst_n]

# Static control: written once, then constant for the life of a capture.
set_false_path -from [get_ports {phase_inc[*]}]

# Egress is a stub (see rx/rx_top.sv). No PHY is chosen, so there is no real
# I/O timing target yet and constraining these to invented numbers would only
# manufacture false failures. This build measures the core datapath; replace
# these with set_input_delay / set_output_delay when the link is picked.
set_false_path -from [get_ports {in_valid adc_i[*] adc_q[*] out_ready}]
set_false_path -to   [get_ports {in_ready out_valid out_overflow iq_i[*] iq_q[*]}]
