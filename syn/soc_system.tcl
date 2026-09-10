# Platform Designer system for the DE1-SoC build: the HPS, its lightweight
# FPGA bridge, and an Avalon-MM master exported for de1soc_core's FIFO.
#
# Generated rather than checked in, like the Quartus project. Run through
# syn/run_syn.ps1 -Top DE1_SoC, or directly:
#
#   qsys-script --script=syn/soc_system.tcl
#   qsys-generate syn/output/soc_system.qsys --synthesis=VERILOG
#
# The memory settings feed the preloader handoff, and this design boots
# Terasic's prebuilt image instead. Building a preloader from this system
# means taking the memory settings from Terasic's GHRD first -- see the
# README's "HPS bring-up".

package require -exact qsys 16.0

create_system soc_system
set_project_property DEVICE_FAMILY {Cyclone V}
set_project_property DEVICE {5CSEMA5F31C6}

# 50 MHz, the datapath's own clock: no crossing on the bus.
add_instance clk_0 clock_source
set_instance_parameter_value clk_0 {clockFrequency} {50000000.0}
set_instance_parameter_value clk_0 {clockFrequencyKnown} {1}
set_instance_parameter_value clk_0 {resetSynchronousEdges} {DEASSERT}

add_instance hps_0 altera_hps
apply_preset hps_0 {JEDEC DDR3-1066G 1GB X8}

# The preset is a generic x8 part. The board's HPS memory is 1 GB of DDR3
# on a 32-bit bus at 400 MHz, and these widths set the pins the image
# drives.
set_instance_parameter_value hps_0 {MEM_DQ_WIDTH} {32}
set_instance_parameter_value hps_0 {MEM_DQ_PER_DQS} {8}
set_instance_parameter_value hps_0 {MEM_ROW_ADDR_WIDTH} {15}
set_instance_parameter_value hps_0 {MEM_COL_ADDR_WIDTH} {10}
set_instance_parameter_value hps_0 {MEM_BANKADDR_WIDTH} {3}
set_instance_parameter_value hps_0 {MEM_CLK_FREQ} {400.0}

# Only the lightweight bridge is used.
set_instance_parameter_value hps_0 {LWH2F_Enable} {true}
set_instance_parameter_value hps_0 {H2F_LW_AXI_CLOCK_FREQ} {50}
set_instance_parameter_value hps_0 {S2F_Width} {0}
set_instance_parameter_value hps_0 {F2S_Width} {0}
set_instance_parameter_value hps_0 {F2SINTERRUPT_Enable} {0}

# Empty the FPGA-to-SDRAM port table: list parameters, one entry per port.
set_instance_parameter_value hps_0 {F2SDRAM_Type} {}
set_instance_parameter_value hps_0 {F2SDRAM_Width} {}

# The peripherals Linux boots and talks to on this board.
set_instance_parameter_value hps_0 {EMAC1_PinMuxing} {HPS I/O Set 0}
set_instance_parameter_value hps_0 {EMAC1_Mode} {RGMII}
set_instance_parameter_value hps_0 {SDIO_PinMuxing} {HPS I/O Set 0}
set_instance_parameter_value hps_0 {SDIO_Mode} {4-bit Data}
set_instance_parameter_value hps_0 {USB1_PinMuxing} {HPS I/O Set 0}
set_instance_parameter_value hps_0 {USB1_Mode} {SDR}
set_instance_parameter_value hps_0 {UART0_PinMuxing} {HPS I/O Set 0}
set_instance_parameter_value hps_0 {UART0_Mode} {No Flow Control}
set_instance_parameter_value hps_0 {I2C0_PinMuxing} {HPS I/O Set 0}
set_instance_parameter_value hps_0 {I2C0_Mode} {I2C}
set_instance_parameter_value hps_0 {I2C1_PinMuxing} {HPS I/O Set 0}
set_instance_parameter_value hps_0 {I2C1_Mode} {I2C}

# AXI to Avalon-MM. The master leaves the system and drives
# iq_avalon_fifo directly, so that slave stays plain RTL.
add_instance mm_bridge_0 altera_avalon_mm_bridge
set_instance_parameter_value mm_bridge_0 {DATA_WIDTH} {32}
set_instance_parameter_value mm_bridge_0 {SYMBOL_WIDTH} {8}
set_instance_parameter_value mm_bridge_0 {ADDRESS_WIDTH} {10}
set_instance_parameter_value mm_bridge_0 {ADDRESS_UNITS} {SYMBOLS}
set_instance_parameter_value mm_bridge_0 {MAX_BURST_SIZE} {1}
set_instance_parameter_value mm_bridge_0 {MAX_PENDING_RESPONSES} {4}
set_instance_parameter_value mm_bridge_0 {USE_AUTO_ADDRESS_WIDTH} {0}
set_instance_parameter_value mm_bridge_0 {PIPELINE_COMMAND} {1}
set_instance_parameter_value mm_bridge_0 {PIPELINE_RESPONSE} {1}

add_connection clk_0.clk hps_0.h2f_lw_axi_clock
add_connection clk_0.clk mm_bridge_0.clk
add_connection clk_0.clk_reset mm_bridge_0.reset
add_connection hps_0.h2f_reset mm_bridge_0.reset
add_connection hps_0.h2f_lw_axi_master mm_bridge_0.s0

# Offset 0 in the bridge's window, so the slave sits at 0xFF200000.
set_connection_parameter_value hps_0.h2f_lw_axi_master/mm_bridge_0.s0 \
    baseAddress {0x00000000}

add_interface clk clock sink
set_interface_property clk EXPORT_OF clk_0.clk_in
add_interface reset reset sink
set_interface_property reset EXPORT_OF clk_0.clk_in_reset
add_interface iq_bus avalon master
set_interface_property iq_bus EXPORT_OF mm_bridge_0.m0
add_interface memory conduit end
set_interface_property memory EXPORT_OF hps_0.memory
add_interface hps_io conduit end
set_interface_property hps_io EXPORT_OF hps_0.hps_io

save_system soc_system.qsys
