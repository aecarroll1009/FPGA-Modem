# Timing constraints for the DE1-SoC board build.
#
# The real pinned-out design, clocked by the board's own 50 MHz oscillator on
# CLOCK_50 (PIN_AF14). The ADC interface is constrained from datasheet
# timing; rx_top.sdc and tx_top.sdc false-path their I/O instead.

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

derive_clock_uncertainty

# -- LTC2308 serial port ----------------------------------------------------
# From the LTC2308 datasheet's Timing Characteristics table, at CL = 25 pF:
#
#   tSUDI  setup, SDI valid before SCK rise      0    ns min
#   tHD    hold,  SDI stable after SCK rise      2.5  ns min
#   tdDO   SDO data valid after SCK fall         12.5 ns max
#   thDO   SDO hold after SCK fall               4    ns min
#   tWHCLK / tWLCLK  SCK high / low time         10   ns min each
#   fSCK   shift clock frequency                 40   MHz max
#
# Board flight time; the parts are centimetres apart.
set adc_trace_max 0.2
set adc_trace_min 0.1

# SCK is one clock high, one low, so 25 MHz -- inside fSCK, with 20 ns of
# high and low time against the 10 ns each required.
create_generated_clock -name adc_sclk -source [get_ports CLOCK_50] \
    -divide_by 2 [get_ports ADC_SCLK]

# DIN is launched from the 50 MHz domain, captured on the SCK rising edge.
set_output_delay -clock adc_sclk -max [expr {0.0 + $adc_trace_max}] [get_ports ADC_DIN]
set_output_delay -clock adc_sclk -min [expr {-2.5 + $adc_trace_min}] [get_ports ADC_DIN]

# SDO is launched on the SCK falling edge and sampled on the next 50 MHz
# edge. That is the default 20 ns relationship; a multicycle here would move
# capture out a full 40 ns SCK period and overstate slack.
set_input_delay -clock adc_sclk -clock_fall \
    -max [expr {12.5 + $adc_trace_max}] [get_ports ADC_DOUT]
set_input_delay -clock adc_sclk -clock_fall \
    -min [expr {4.0 + $adc_trace_min}] [get_ports ADC_DOUT]

# CONVST is a conversion strobe, not a sampled interface. Its requirements
# are pulse widths (tWHCONV, tWLCONVST, tHCONVST, tACQ), met by
# ltc2308_ctrl's cycle counts and checked in de1soc/tb_ltc2308_ctrl.sv.
set_false_path -to [get_ports ADC_CONVST]

# -- IQ egress --------------------------------------------------------------
# A UART receiver recovers bit timing from the start edge, so there is no
# relationship to constrain. The divisor is exact: 50 MHz / 20 = 2.5 Mbaud.
set_false_path -to [get_ports UART_TX]

# -- user I/O ---------------------------------------------------------------
# KEY[0] is the reset: debounced on the board, asynchronous by nature.
set_false_path -from [get_ports {KEY[*]}]

# Slide switches: static operator input. SW[0] selects the capture mode.
set_false_path -from [get_ports {SW[*]}]

# LEDs and displays are read by a person.
set_false_path -to [get_ports {LEDR[*]}]
set_false_path -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
