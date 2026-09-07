// Simulation-only LTC2308 slave model: feeds conversion results to
// ltc2308_ctrl from a testbench-supplied stimulus.
//
// A data source, not a protocol checker -- tb_ltc2308_ctrl.sv has its own
// model for that. Reproduces the Figure 9 read timing only: SDO holds stale
// until tCONV elapses, then B11, then one bit per SCK falling edge.
// conv_count increments per conversion, for indexing next_code.

`timescale 1ns/1ps

module ltc2308_model #(
    // CONVST to MSB, matching ltc2308_ctrl's ShiftBegin.
    parameter int TCONV_WAIT_CYCLES = 80
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        adc_convst,
    input  logic        adc_sclk,
    input  logic [11:0] next_code,

    output logic        adc_dout,
    output logic [15:0] conv_count
);

    logic [11:0] pending_code;
    logic [10:0] code_word;
    logic [3:0]  fall_cnt;

    always @(posedge adc_convst or negedge adc_sclk or negedge rst_n) begin
        if (!rst_n) begin
            conv_count <= '0;
            fall_cnt   <= '0;
            code_word  <= '0;
            adc_dout   <= 1'b0;
        end else if (adc_convst) begin
            // Blocking: re-read after the wait below, so fix it now.
            /* verilator lint_off BLKSEQ */
            pending_code = next_code;
            /* verilator lint_on BLKSEQ */
            conv_count  <= conv_count + 1'b1;
            fall_cnt    <= '0;
            repeat (TCONV_WAIT_CYCLES) @(posedge clk);
            adc_dout  <= pending_code[11];
            code_word <= pending_code[10:0];
        end else begin
            // B10 after the 1st fall down to B0 after the 11th. The 12th
            // is Hi-Z on real silicon, modelled as 0 and never read.
            fall_cnt <= fall_cnt + 1'b1;
            if (fall_cnt <= 4'd10)
                adc_dout <= code_word[10 - fall_cnt];
            else
                adc_dout <= 1'b0;
        end
    end

endmodule
