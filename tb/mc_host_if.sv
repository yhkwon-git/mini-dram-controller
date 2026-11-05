// Host port bundle for the random testbench. The classes in mc_tb_pkg drive
// and sample it through a virtual interface.
`timescale 1ns/1ps

// Driven and read through a virtual interface, which Verilator's lint does not follow.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface mc_host_if (input logic clk);
  logic                           rst_n;
  logic                           req_valid;
  logic                           req_ready;
  logic                           req_write;
  logic [dram_pkg::ADDR_BITS-1:0] req_addr;
  logic [dram_pkg::DATA_BITS-1:0] req_wdata;
  logic                           rsp_valid;
  logic                           rsp_ready;
  logic [dram_pkg::DATA_BITS-1:0] rsp_rdata;
  logic                           rsp_err;

  // Edge counter. Read at a posedge it gives the index of that edge, the same
  // value for a request accepted and a response taken on it.
  longint cyc;
  initial cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;
endinterface
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
