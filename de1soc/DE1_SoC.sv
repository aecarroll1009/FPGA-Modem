// DE1-SoC board top level: pins, the Platform Designer system, and
// de1soc_core. Structural only; the testbenches drive de1soc_core.
//
// soc_system comes from syn/soc_system.tcl and holds the HPS and its
// lightweight bridge. Its Avalon master drives the core's IQ FIFO, which
// hps/iq_streamd.c drains and sends on as UDP.
//
// The HPS_* ports are the ARM side's own pins and do not cross into the
// fabric: DDR3, gigabit Ethernet, the SD card Linux boots from, USB, a
// console UART, and two I2C buses.

`timescale 1ns/1ps

module DE1_SoC (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,
    output logic [6:0]  HEX0,
    output logic [6:0]  HEX1,
    output logic [6:0]  HEX2,
    output logic [6:0]  HEX3,
    output logic [6:0]  HEX4,
    output logic [6:0]  HEX5,

    // LTC2308 ADC.
    output logic        ADC_CONVST,
    output logic        ADC_SCLK,
    output logic        ADC_DIN,
    input  logic        ADC_DOUT,

    // HPS DDR3.
    output logic [14:0] HPS_DDR3_ADDR,
    output logic [2:0]  HPS_DDR3_BA,
    output logic        HPS_DDR3_CAS_N,
    output logic        HPS_DDR3_CK_N,
    output logic        HPS_DDR3_CK_P,
    output logic        HPS_DDR3_CKE,
    output logic        HPS_DDR3_CS_N,
    output logic [3:0]  HPS_DDR3_DM,
    inout  wire  [31:0] HPS_DDR3_DQ,
    inout  wire  [3:0]  HPS_DDR3_DQS_N,
    inout  wire  [3:0]  HPS_DDR3_DQS_P,
    output logic        HPS_DDR3_ODT,
    output logic        HPS_DDR3_RAS_N,
    output logic        HPS_DDR3_RESET_N,
    input  logic        HPS_DDR3_RZQ,
    output logic        HPS_DDR3_WE_N,

    // HPS gigabit Ethernet, RGMII.
    output logic        HPS_ENET_GTX_CLK,
    output logic        HPS_ENET_MDC,
    inout  wire         HPS_ENET_MDIO,
    input  logic        HPS_ENET_RX_CLK,
    input  logic [3:0]  HPS_ENET_RX_DATA,
    input  logic        HPS_ENET_RX_DV,
    output logic [3:0]  HPS_ENET_TX_DATA,
    output logic        HPS_ENET_TX_EN,

    // HPS SD card, USB, console, and I2C.
    output logic        HPS_SD_CLK,
    inout  wire         HPS_SD_CMD,
    inout  wire  [3:0]  HPS_SD_DATA,
    input  logic        HPS_USB_CLKOUT,
    inout  wire  [7:0]  HPS_USB_DATA,
    input  logic        HPS_USB_DIR,
    input  logic        HPS_USB_NXT,
    output logic        HPS_USB_STP,
    input  logic        HPS_UART_RX,
    output logic        HPS_UART_TX,
    inout  wire         HPS_I2C0_SCLK,
    inout  wire         HPS_I2C0_SDAT,
    inout  wire         HPS_I2C1_SCLK,
    inout  wire         HPS_I2C1_SDAT
);

    // Avalon-MM, from the lightweight bridge to the core's FIFO.
    wire [9:0]  iq_address;
    wire        iq_read, iq_write;
    wire [31:0] iq_readdata, iq_writedata;
    wire        iq_readdatavalid, iq_waitrequest;

    // Byte addresses off the bridge, word addresses into the slave.
    wire [2:0]  avs_address = iq_address[4:2];

    // Unused: the slave takes no burst, partial word, or debug access.
    wire [0:0]  iq_burstcount;
    wire [3:0]  iq_byteenable;
    wire        iq_debugaccess;
    wire _unused_ok = &{1'b0, iq_burstcount, iq_byteenable, iq_debugaccess,
                        iq_address[9:5], iq_address[1:0]};

    de1soc_core u_core (
        .CLOCK_50          (CLOCK_50),
        .KEY               (KEY),
        .SW                (SW),
        .LEDR              (LEDR),
        .HEX0              (HEX0), .HEX1 (HEX1), .HEX2 (HEX2),
        .HEX3              (HEX3), .HEX4 (HEX4), .HEX5 (HEX5),
        .ADC_CONVST        (ADC_CONVST),
        .ADC_SCLK          (ADC_SCLK),
        .ADC_DIN           (ADC_DIN),
        .ADC_DOUT          (ADC_DOUT),
        .avs_address       (avs_address),
        .avs_read          (iq_read),
        .avs_readdata      (iq_readdata),
        .avs_readdatavalid (iq_readdatavalid),
        .avs_waitrequest   (iq_waitrequest),
        .avs_write         (iq_write),
        .avs_writedata     (iq_writedata)
    );

    soc_system u_soc (
        .clk_clk        (CLOCK_50),
        .reset_reset_n  (KEY[0]),

        .iq_bus_address       (iq_address),
        .iq_bus_read          (iq_read),
        .iq_bus_readdata      (iq_readdata),
        .iq_bus_readdatavalid (iq_readdatavalid),
        .iq_bus_waitrequest   (iq_waitrequest),
        .iq_bus_write         (iq_write),
        .iq_bus_writedata     (iq_writedata),
        .iq_bus_burstcount    (iq_burstcount),
        .iq_bus_byteenable    (iq_byteenable),
        .iq_bus_debugaccess   (iq_debugaccess),

        .memory_mem_a       (HPS_DDR3_ADDR),
        .memory_mem_ba      (HPS_DDR3_BA),
        .memory_mem_ck      (HPS_DDR3_CK_P),
        .memory_mem_ck_n    (HPS_DDR3_CK_N),
        .memory_mem_cke     (HPS_DDR3_CKE),
        .memory_mem_cs_n    (HPS_DDR3_CS_N),
        .memory_mem_ras_n   (HPS_DDR3_RAS_N),
        .memory_mem_cas_n   (HPS_DDR3_CAS_N),
        .memory_mem_we_n    (HPS_DDR3_WE_N),
        .memory_mem_reset_n (HPS_DDR3_RESET_N),
        .memory_mem_dq      (HPS_DDR3_DQ),
        .memory_mem_dqs     (HPS_DDR3_DQS_P),
        .memory_mem_dqs_n   (HPS_DDR3_DQS_N),
        .memory_mem_odt     (HPS_DDR3_ODT),
        .memory_mem_dm      (HPS_DDR3_DM),
        .memory_oct_rzqin   (HPS_DDR3_RZQ),

        .hps_io_hps_io_emac1_inst_TX_CLK (HPS_ENET_GTX_CLK),
        .hps_io_hps_io_emac1_inst_TXD0   (HPS_ENET_TX_DATA[0]),
        .hps_io_hps_io_emac1_inst_TXD1   (HPS_ENET_TX_DATA[1]),
        .hps_io_hps_io_emac1_inst_TXD2   (HPS_ENET_TX_DATA[2]),
        .hps_io_hps_io_emac1_inst_TXD3   (HPS_ENET_TX_DATA[3]),
        .hps_io_hps_io_emac1_inst_RXD0   (HPS_ENET_RX_DATA[0]),
        .hps_io_hps_io_emac1_inst_RXD1   (HPS_ENET_RX_DATA[1]),
        .hps_io_hps_io_emac1_inst_RXD2   (HPS_ENET_RX_DATA[2]),
        .hps_io_hps_io_emac1_inst_RXD3   (HPS_ENET_RX_DATA[3]),
        .hps_io_hps_io_emac1_inst_MDIO   (HPS_ENET_MDIO),
        .hps_io_hps_io_emac1_inst_MDC    (HPS_ENET_MDC),
        .hps_io_hps_io_emac1_inst_RX_CTL (HPS_ENET_RX_DV),
        .hps_io_hps_io_emac1_inst_TX_CTL (HPS_ENET_TX_EN),
        .hps_io_hps_io_emac1_inst_RX_CLK (HPS_ENET_RX_CLK),

        .hps_io_hps_io_sdio_inst_CMD (HPS_SD_CMD),
        .hps_io_hps_io_sdio_inst_D0  (HPS_SD_DATA[0]),
        .hps_io_hps_io_sdio_inst_D1  (HPS_SD_DATA[1]),
        .hps_io_hps_io_sdio_inst_CLK (HPS_SD_CLK),
        .hps_io_hps_io_sdio_inst_D2  (HPS_SD_DATA[2]),
        .hps_io_hps_io_sdio_inst_D3  (HPS_SD_DATA[3]),

        .hps_io_hps_io_usb1_inst_D0  (HPS_USB_DATA[0]),
        .hps_io_hps_io_usb1_inst_D1  (HPS_USB_DATA[1]),
        .hps_io_hps_io_usb1_inst_D2  (HPS_USB_DATA[2]),
        .hps_io_hps_io_usb1_inst_D3  (HPS_USB_DATA[3]),
        .hps_io_hps_io_usb1_inst_D4  (HPS_USB_DATA[4]),
        .hps_io_hps_io_usb1_inst_D5  (HPS_USB_DATA[5]),
        .hps_io_hps_io_usb1_inst_D6  (HPS_USB_DATA[6]),
        .hps_io_hps_io_usb1_inst_D7  (HPS_USB_DATA[7]),
        .hps_io_hps_io_usb1_inst_CLK (HPS_USB_CLKOUT),
        .hps_io_hps_io_usb1_inst_STP (HPS_USB_STP),
        .hps_io_hps_io_usb1_inst_DIR (HPS_USB_DIR),
        .hps_io_hps_io_usb1_inst_NXT (HPS_USB_NXT),

        .hps_io_hps_io_uart0_inst_RX (HPS_UART_RX),
        .hps_io_hps_io_uart0_inst_TX (HPS_UART_TX),

        .hps_io_hps_io_i2c0_inst_SDA (HPS_I2C0_SDAT),
        .hps_io_hps_io_i2c0_inst_SCL (HPS_I2C0_SCLK),
        .hps_io_hps_io_i2c1_inst_SDA (HPS_I2C1_SDAT),
        .hps_io_hps_io_i2c1_inst_SCL (HPS_I2C1_SCLK)
    );

endmodule
