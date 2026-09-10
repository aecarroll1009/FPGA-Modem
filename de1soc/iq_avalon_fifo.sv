// Avalon-MM slave holding IQ pairs for the HPS to drain over the
// lightweight HPS-to-FPGA bridge.
//
// Write side takes one pair per iq_valid; read side pops one 32-bit
// {i, q} word per DATA read. Fixed read latency of 1, so waitrequest is
// tied low and readdatavalid is the read strobe delayed a clock.
// CTRL and PHASE_INC are the host's tuning and rate controls.
//
// Register map (word addresses), mirrored in hps/iq_regs.h:
//   0  ID         RO  0x53445202
//   1  CTRL       RW  [0] full-rate tap, [1] enable, [2] flush (self-clearing)
//   2  PHASE_INC  RW  [PHASE_BITS-1:0] LO tuning word
//   3  LEVEL      RO  words available
//   4  STATUS     RO  [15:0] pairs dropped (saturating), [16] overflow sticky
//   5  DATA       RO  pops {i, q}, zero when empty

`timescale 1ns/1ps

module iq_avalon_fifo #(
    parameter int DEPTH      = 4096,
    parameter int DATA_BITS  = 16,
    parameter int PHASE_BITS = 24,

    // Tuning word held until the host writes PHASE_INC.
    parameter logic [PHASE_BITS-1:0] PHASE_INC_INIT = '0
) (
    input  logic clk,
    input  logic rst_n,

    // Avalon-MM slave, read latency 1.
    input  logic [2:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    output logic        avs_readdatavalid,
    output logic        avs_waitrequest,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,

    // Datapath side.
    input  logic                        iq_valid,
    input  logic signed [DATA_BITS-1:0] iq_i,
    input  logic signed [DATA_BITS-1:0] iq_q,

    // Host-written control, out to the datapath.
    output logic                  tap_full,
    output logic                  enable,
    output logic [PHASE_BITS-1:0] phase_inc,

    // Observability for the board's LEDs and displays.
    output logic [15:0] level,
    output logic [15:0] drops,
    output logic        overflow
);

    localparam int AddrW = $clog2(DEPTH);

    // One bit wider than the address, to represent DEPTH itself.
    localparam int CntW = AddrW + 1;

    localparam logic [31:0] IdCode = 32'h5344_5202;

    localparam logic [2:0] RegId    = 3'd0, RegCtrl   = 3'd1, RegPhase = 3'd2,
                           RegLevel = 3'd3, RegStatus = 3'd4, RegData  = 3'd5;

    // 2 * DATA_BITS must fill the word the bridge carries.
    initial begin
        if (2 * DATA_BITS != 32)
            $fatal(1, "iq_avalon_fifo: DATA_BITS=%0d does not pack into 32 bits", DATA_BITS);
    end

    // Unused command bits, named so lint does not flag them.
    wire _unused_ok = &{1'b0, avs_writedata[31:3]};

    logic [31:0]      mem [0:DEPTH-1];
    logic [AddrW-1:0] wr_ptr, rd_ptr;
    logic [CntW-1:0]  count;

    wire fifo_full  = (count == CntW'(DEPTH));
    wire fifo_empty = (count == CntW'(0));

    wire take  = iq_valid && enable;
    wire do_wr = take && !fifo_full;
    wire do_rd = avs_read && (avs_address == RegData) && !fifo_empty;

    wire flush = avs_write && (avs_address == RegCtrl) && avs_writedata[2];

    // -- storage -----------------------------------------------------------
    // Free-running registered read: fifo_q trails rd_ptr by one clock.
    logic [31:0] fifo_q;

    always_ff @(posedge clk) begin
        if (do_wr) mem[wr_ptr] <= {iq_i, iq_q};
        fifo_q <= mem[rd_ptr];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else if (flush) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;   // wraps mod DEPTH
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;

            case ({do_wr, do_rd})
                2'b10:   count <= count + CntW'(1);
                2'b01:   count <= count - CntW'(1);
                default: count <= count;
            endcase
        end
    end

    // -- drop accounting ---------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drops    <= '0;
            overflow <= 1'b0;
        end else if (flush) begin
            drops    <= '0;
            overflow <= 1'b0;
        end else if (take && fifo_full) begin
            overflow <= 1'b1;
            if (drops != 16'hFFFF) drops <= drops + 1'b1;
        end
    end

    // -- control registers -------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Idle until the host opts in.
            tap_full  <= 1'b1;
            enable    <= 1'b0;
            phase_inc <= PHASE_INC_INIT;
        end else if (avs_write) begin
            case (avs_address)
                RegCtrl: begin
                    tap_full <= avs_writedata[0];
                    enable   <= avs_writedata[1];
                end
                RegPhase: phase_inc <= avs_writedata[PHASE_BITS-1:0];
                default:  ;
            endcase
        end
    end

    // -- read path ---------------------------------------------------------
    // The address and empty flag are delayed to match fifo_q. The control
    // and status registers are muxed live, so they read a clock fresher.
    logic [2:0] addr_q;
    logic       empty_q;

    assign avs_waitrequest = 1'b0;

    always_ff @(posedge clk) begin
        addr_q  <= avs_address;
        empty_q <= fifo_empty;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) avs_readdatavalid <= 1'b0;
        else        avs_readdatavalid <= avs_read;
    end

    assign level = 16'(count);

    always_comb begin
        case (addr_q)
            RegId:     avs_readdata = IdCode;
            RegCtrl:   avs_readdata = {30'd0, enable, tap_full};
            RegPhase:  avs_readdata = 32'(phase_inc);
            RegLevel:  avs_readdata = 32'(level);
            RegStatus: avs_readdata = {15'd0, overflow, drops};
            RegData:   avs_readdata = empty_q ? 32'd0 : fifo_q;
            default:   avs_readdata = 32'd0;
        endcase
    end

endmodule
