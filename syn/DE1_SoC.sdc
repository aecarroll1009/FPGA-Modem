# Timing constraints for the DE1-SoC board build.
#
# Unlike rx_top.sdc and tx_top.sdc, this is a real pinned-out design, so the
# clock here is the board's actual oscillator rather than a stand-in: 50 MHz
# on CLOCK_50 (PIN_AF14). The datapath needs 19 clocks per sample and the
# LTC2308 tops out at 500 kS/s, so 50 MHz is a 5.3x margin over the 9.5 MHz
# the converter can actually demand -- see the README's rate budget.

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

derive_clock_uncertainty

# KEY[0] is the reset. It is a debounced Schmitt-trigger output that is held
# for many milliseconds by a human finger, so it is asynchronous to the
# clock by nature and there is nothing to constrain.
set_false_path -from [get_ports {KEY[*]}]

# Slide switches: static operator input, read whenever.
set_false_path -from [get_ports {SW[*]}]

# LEDs and seven-segment displays are looked at by a person. Any timing
# relationship to the clock is meaningless at human timescales.
set_false_path -to [get_ports {LEDR[*]}]
set_false_path -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]

# The LTC2308 port is pinned out but parked -- DE1_SoC.sv drives these to
# constants because there is no controller yet. Replace these false paths
# with real set_input_delay / set_output_delay against the converter's
# datasheet timing when the SPI master lands; leaving them false-pathed then
# would be constraining a real synchronous interface as if it did not exist.
set_false_path -to   [get_ports {ADC_CONVST ADC_SCLK ADC_DIN}]
set_false_path -from [get_ports {ADC_DOUT}]
