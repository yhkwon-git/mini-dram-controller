// Top wrapper: host_if + mem_ctrl + dram_model (for Verilator / SV TB).
`timescale 1ns/1ps

module mem_ctrl_top
  import dram_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  input  logic              req_valid,
  output logic              req_ready,
  input  logic              req_write,
  input  logic [ADDR_BITS-1:0] req_addr,
  input  logic [DATA_BITS-1:0] req_wdata,

  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [DATA_BITS-1:0] rsp_rdata,
  output logic              rsp_err,

  // Model observability (TB / debug)
  output logic              dram_page_hit,
  output logic              dram_access_err,
  output logic [NUM_BANKS-1:0] dram_bank_open
);

  logic              c_req_valid, c_req_ready, c_req_write;
  logic [ADDR_BITS-1:0] c_req_addr;
  logic [DATA_BITS-1:0] c_req_wdata;
  logic              c_rsp_valid, c_rsp_ready, c_rsp_err;
  logic [DATA_BITS-1:0] c_rsp_rdata;

  dram_cmd_e         d_cmd;
  logic [$clog2(NUM_BANKS)-1:0] d_bank;
  logic [ROW_BITS-1:0] d_row;
  logic [COL_BITS-1:0] d_col;
  logic [DATA_BITS-1:0] d_wdata;
  logic              d_busy, d_data_valid, d_page_hit;
  logic [DATA_BITS-1:0] d_rdata;
  logic              d_access_err;
  logic [NUM_BANKS-1:0] d_bank_open;

  host_if #(
    .ADDR_W(ADDR_BITS),
    .DATA_W(DATA_BITS)
  ) u_host (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_write(req_write),
    .req_addr(req_addr),
    .req_wdata(req_wdata),
    .rsp_valid(rsp_valid),
    .rsp_ready(rsp_ready),
    .rsp_rdata(rsp_rdata),
    .rsp_err(rsp_err),
    .ctrl_req_valid(c_req_valid),
    .ctrl_req_ready(c_req_ready),
    .ctrl_req_write(c_req_write),
    .ctrl_req_addr(c_req_addr),
    .ctrl_req_wdata(c_req_wdata),
    .ctrl_rsp_valid(c_rsp_valid),
    .ctrl_rsp_ready(c_rsp_ready),
    .ctrl_rsp_rdata(c_rsp_rdata),
    .ctrl_rsp_err(c_rsp_err)
  );

  mem_ctrl u_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(c_req_valid),
    .req_ready(c_req_ready),
    .req_write(c_req_write),
    .req_addr(c_req_addr),
    .req_wdata(c_req_wdata),
    .rsp_valid(c_rsp_valid),
    .rsp_ready(c_rsp_ready),
    .rsp_rdata(c_rsp_rdata),
    .rsp_err(c_rsp_err),
    .dram_cmd(d_cmd),
    .dram_bank(d_bank),
    .dram_row(d_row),
    .dram_col(d_col),
    .dram_wdata(d_wdata),
    .dram_busy(d_busy),
    .dram_data_valid(d_data_valid),
    .dram_rdata(d_rdata),
    .dram_page_hit(d_page_hit)
  );

  dram_model u_dram (
    .clk(clk),
    .rst_n(rst_n),
    .cmd(d_cmd),
    .bank(d_bank),
    .row(d_row),
    .col(d_col),
    .wdata(d_wdata),
    .busy(d_busy),
    .data_valid(d_data_valid),
    .rdata(d_rdata),
    .page_hit(d_page_hit),
    .access_err(d_access_err),
    .bank_open_oh(d_bank_open)
  );

  assign dram_page_hit   = d_page_hit;
  assign dram_access_err = d_access_err;
  assign dram_bank_open  = d_bank_open;

endmodule
