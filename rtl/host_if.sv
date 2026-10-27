// Simple host request/response interface (educational alternative to AXI-lite).
// Skeleton only — no protocol checking yet.
`timescale 1ns/1ps

module host_if #(
  parameter int ADDR_W = 14,
  parameter int DATA_W = 32
) (
  input  logic              clk,
  input  logic              rst_n,

  // Host request
  input  logic              req_valid,
  output logic              req_ready,
  input  logic              req_write,   // 1=write, 0=read
  input  logic [ADDR_W-1:0] req_addr,
  input  logic [DATA_W-1:0] req_wdata,

  // Host response
  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [DATA_W-1:0] rsp_rdata,
  output logic              rsp_err,

  // To memory controller (pass-through for now)
  output logic              ctrl_req_valid,
  input  logic              ctrl_req_ready,
  output logic              ctrl_req_write,
  output logic [ADDR_W-1:0] ctrl_req_addr,
  output logic [DATA_W-1:0] ctrl_req_wdata,

  input  logic              ctrl_rsp_valid,
  output logic              ctrl_rsp_ready,
  input  logic [DATA_W-1:0] ctrl_rsp_rdata,
  input  logic              ctrl_rsp_err
);

  // Skeleton: combinational connect. Add skid/ready staging later.
  assign ctrl_req_valid = req_valid;
  assign req_ready      = ctrl_req_ready;
  assign ctrl_req_write = req_write;
  assign ctrl_req_addr  = req_addr;
  assign ctrl_req_wdata = req_wdata;

  assign rsp_valid      = ctrl_rsp_valid;
  assign ctrl_rsp_ready = rsp_ready;
  assign rsp_rdata      = ctrl_rsp_rdata;
  assign rsp_err        = ctrl_rsp_err;

endmodule
