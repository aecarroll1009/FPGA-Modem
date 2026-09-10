// Avalon-MM master tasks for testbenches driving iq_avalon_fifo.
//
// One transfer per clock, driven on the falling edge.
//
// The includer must declare clk, avs_address, avs_read, avs_readdata,
// avs_write, and avs_writedata. Include once per module: the tasks are
// declared at module scope.

task automatic av_write(input logic [2:0] a, input logic [31:0] d);
    @(negedge clk);
    avs_address   = a;
    avs_writedata = d;
    avs_write     = 1'b1;
    @(negedge clk);
    avs_write     = 1'b0;
endtask

// Read latency 1: the data holds for the clock after the request.
task automatic av_read(input logic [2:0] a, output logic [31:0] d);
    @(negedge clk);
    avs_address = a;
    avs_read    = 1'b1;
    @(negedge clk);
    avs_read    = 1'b0;
    d = avs_readdata;
endtask
