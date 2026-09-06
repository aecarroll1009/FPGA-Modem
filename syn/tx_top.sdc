# Timing constraints for tx_top.
#
# Same target as rx_top.sdc, for the same reason: the mixer's 19-clocks-per-
# sample rate is direction-independent (RX and TX run the same CORDIC
# iterations), so the 45.6 MHz floor and the 50 MHz constraint carry over
# unchanged. See rx_top.sdc for the derivation.

create_clock -name clk -period 20.000 [get_ports clk]

derive_clock_uncertainty

# Asynchronous, held for many cycles at power-up.
set_false_path -from [get_ports rst_n]

# Static control: written once, then constant for the life of a transmission.
set_false_path -from [get_ports {phase_inc[*]}]

# Egress is a stub (see tx/tx_top.sv). No PHY is chosen, so there is no real
# I/O timing target yet and constraining these to invented numbers would only
# manufacture false failures. This build measures the core datapath; replace
# these with set_input_delay / set_output_delay when the link is picked.
set_false_path -from [get_ports {in_valid bb_i[*] bb_q[*] out_ready}]
set_false_path -to   [get_ports {in_ready out_valid out_overflow rf_i[*] rf_q[*]}]
