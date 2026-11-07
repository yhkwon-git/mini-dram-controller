// Top wrapper: host_if + mem_ctrl + dram_model (for Verilator / SV TB).
// The mem_ctrl parameters pass through so a testbench can sweep them.
`timescale 1ns/1ps

module mem_ctrl_top
  import dram_pkg::*;
#(
  parameter int DEPTH        = QUEUE_DEPTH,
  parameter bit FR_FCFS      = 1'b1,
  parameter bit WDRAIN       = 1'b1,
  parameter int WR_HI        = 6,
  parameter int WR_LO        = 2,
  parameter int PAGE_POLICY  = PAGE_OPEN,
  parameter int PAGE_TIMEOUT = 16,
  parameter int ADDR_MAP     = MAP_XOR,
  parameter int CMD_BUS      = 2,
  parameter int REF_MODE     = REF_BANK,
  parameter bit RFM_EARLY    = 1'b1,
  parameter int RD_PIPE      = 4,
  parameter int STARVE_LIMIT = 160,
  parameter int REF_URGENT   = 4
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 req_valid,
  output logic                 req_ready,
  input  logic                 req_write,
  input  logic [ADDR_BITS-1:0] req_addr,
  input  logic [DATA_BITS-1:0] req_wdata,

  output logic                 rsp_valid,
  input  logic                 rsp_ready,
  output logic [DATA_BITS-1:0] rsp_rdata,
  output logic                 rsp_err,

  // Model observability (TB / debug)
  output logic                 dram_page_hit,
  output logic                 dram_access_err,
  output logic [NUM_BANKS-1:0] dram_bank_open
);

  logic                 c_req_valid, c_req_ready, c_req_write;
  logic [ADDR_BITS-1:0] c_req_addr;
  logic [DATA_BITS-1:0] c_req_wdata;
  logic                 c_rsp_valid, c_rsp_ready, c_rsp_err;
  logic [DATA_BITS-1:0] c_rsp_rdata;
  /* verilator lint_off UNUSEDSIGNAL */
  logic                 c_q_empty;  // used by High-Speed Link Lite's lane BIST, not here
  /* verilator lint_on UNUSEDSIGNAL */

  dram_cmd_e            d_rcmd, d_ccmd;
  logic [BANK_BITS-1:0] d_rbank, d_cbank;
  logic [ROW_BITS-1:0]  d_row;
  logic [COL_BITS-1:0]  d_col;
  logic                 d_ap;
  logic                 d_wdata_en;
  logic [DATA_BITS-1:0] d_wdata;
  logic                 d_busy, d_data_valid, d_page_hit, d_access_err;
  logic [DATA_BITS-1:0] d_rdata;
  logic [NUM_BANKS-1:0] d_bank_open;

  host_if #(
    .ADDR_W(ADDR_BITS),
    .DATA_W(DATA_BITS)
  ) u_host (
    .clk            (clk),
    .rst_n          (rst_n),
    .req_valid      (req_valid),
    .req_ready      (req_ready),
    .req_write      (req_write),
    .req_addr       (req_addr),
    .req_wdata      (req_wdata),
    .rsp_valid      (rsp_valid),
    .rsp_ready      (rsp_ready),
    .rsp_rdata      (rsp_rdata),
    .rsp_err        (rsp_err),
    .ctrl_req_valid (c_req_valid),
    .ctrl_req_ready (c_req_ready),
    .ctrl_req_write (c_req_write),
    .ctrl_req_addr  (c_req_addr),
    .ctrl_req_wdata (c_req_wdata),
    .ctrl_rsp_valid (c_rsp_valid),
    .ctrl_rsp_ready (c_rsp_ready),
    .ctrl_rsp_rdata (c_rsp_rdata),
    .ctrl_rsp_err   (c_rsp_err)
  );

  mem_ctrl #(
    .DEPTH        (DEPTH),
    .FR_FCFS      (FR_FCFS),
    .WDRAIN       (WDRAIN),
    .WR_HI        (WR_HI),
    .WR_LO        (WR_LO),
    .PAGE_POLICY  (PAGE_POLICY),
    .PAGE_TIMEOUT (PAGE_TIMEOUT),
    .ADDR_MAP     (ADDR_MAP),
    .CMD_BUS      (CMD_BUS),
    .REF_MODE     (REF_MODE),
    .RFM_EARLY    (RFM_EARLY),
    .RD_PIPE      (RD_PIPE),
    .STARVE_LIMIT (STARVE_LIMIT),
    .REF_URGENT   (REF_URGENT)
  ) u_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .req_valid       (c_req_valid),
    .req_ready       (c_req_ready),
    .req_write       (c_req_write),
    .req_addr        (c_req_addr),
    .req_wdata       (c_req_wdata),
    .rsp_valid       (c_rsp_valid),
    .rsp_ready       (c_rsp_ready),
    .rsp_rdata       (c_rsp_rdata),
    .rsp_err         (c_rsp_err),
    .dram_rcmd       (d_rcmd),
    .dram_rbank      (d_rbank),
    .dram_row        (d_row),
    .dram_ccmd       (d_ccmd),
    .dram_cbank      (d_cbank),
    .dram_col        (d_col),
    .dram_ap         (d_ap),
    .dram_wdata_en   (d_wdata_en),
    .dram_wdata      (d_wdata),
    .dram_data_valid (d_data_valid),
    .dram_rdata      (d_rdata),
    .q_empty         (c_q_empty)
  );

  dram_model u_dram (
    .clk          (clk),
    .rst_n        (rst_n),
    .rcmd         (d_rcmd),
    .rbank        (d_rbank),
    .row          (d_row),
    .ccmd         (d_ccmd),
    .cbank        (d_cbank),
    .col          (d_col),
    .ap           (d_ap),
    .wdata_en     (d_wdata_en),
    .wdata        (d_wdata),
    .busy         (d_busy),
    .data_valid   (d_data_valid),
    .rdata        (d_rdata),
    .page_hit     (d_page_hit),
    .access_err   (d_access_err),
    .bank_open_oh (d_bank_open)
  );

  assign dram_page_hit   = d_page_hit;
  assign dram_access_err = d_access_err;
  assign dram_bank_open  = d_bank_open;

  // The tRFC window is visible to waveforms; the controller counts tRFC itself.
  wire unused_busy = d_busy;

endmodule
