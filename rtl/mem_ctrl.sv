// Mini memory controller v2: request queue + command-level scheduler.
//
//   mc_queue    accepted requests until their RD/WR is issued
//   mc_bank x4  open row and same-bank timing (tRCD tRP tRAS tRC tRTP tWR)
//   mc_chan     channel timing (tCCD tRRD tFAW tWTR tRTW tRFC)
//   mc_refresh  one REF owed per tREFI, paid back when idle or when urgent
//   mc_sched    one DRAM command per cycle (FR-FCFS or FCFS)
//   mc_resp     tags, read-return FIFO, write-data pipeline, in-order responses
//
// The DRAM side is DFI-like: commands with fixed data latencies (RL, WL) and
// no busy signal; the controller tracks every timing rule itself.
`timescale 1ns/1ps

module mem_ctrl
  import dram_pkg::*;
#(
  parameter int DEPTH        = QUEUE_DEPTH,
  parameter bit FR_FCFS      = 1'b1,  // 0 = oldest ready command first
  parameter int RD_PIPE      = 4,     // RDs in flight on the DRAM bus (v1: 1)
  parameter int STARVE_LIMIT = 160,   // cycles before the oldest request overrides row hits
  parameter int REF_URGENT   = 4      // owed REFs that stop new traffic
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

  output dram_cmd_e            dram_cmd,
  output logic [BANK_BITS-1:0] dram_bank,
  output logic [ROW_BITS-1:0]  dram_row,
  output logic [COL_BITS-1:0]  dram_col,
  output logic                 dram_wdata_en,
  output logic [DATA_BITS-1:0] dram_wdata,
  input  logic                 dram_data_valid,
  input  logic [DATA_BITS-1:0] dram_rdata
);

  localparam int AW = $clog2(DEPTH);

  logic                            acc;
  logic                            q_has_free;
  logic [DEPTH-1:0]                q_valid, q_write;
  logic [DEPTH-1:0][BANK_BITS-1:0] q_bank;
  logic [DEPTH-1:0][ROW_BITS-1:0]  q_row;
  logic [DEPTH-1:0][COL_BITS-1:0]  q_col;
  logic [DEPTH-1:0][DATA_BITS-1:0] q_wdata;
  logic [DEPTH-1:0][TAG_BITS-1:0]  q_tag;
  logic [DEPTH-1:0][7:0]           q_wait;
  logic [DEPTH-1:0][DEPTH-1:0]     q_older, q_dep;

  logic [TAG_BITS-1:0]             tag_alloc;
  logic                            tag_free, rd_slot_ok;

  logic [NUM_BANKS-1:0]                bank_open, bank_act_ok, bank_col_ok, bank_pre_ok;
  logic [NUM_BANKS-1:0][ROW_BITS-1:0]  bank_row;
  logic                                chan_act_ok, chan_rd_ok, chan_wr_ok, chan_any_ok;
  logic                                ref_hold;
  logic [3:0]                          ref_owed;

  dram_cmd_e                       cmd;
  logic [BANK_BITS-1:0]            cmd_bank;
  logic [ROW_BITS-1:0]             cmd_row;
  logic [COL_BITS-1:0]             cmd_col;
  logic                            serve;
  logic [AW-1:0]                   serve_idx;

  assign req_ready = q_has_free && tag_free;
  assign acc       = req_valid && req_ready;
  assign rsp_err   = 1'b0;

  mc_queue #(.DEPTH(DEPTH)) u_queue (
    .clk        (clk),
    .rst_n      (rst_n),
    .push       (acc),
    .push_write (req_write),
    .push_addr  (req_addr),
    .push_wdata (req_wdata),
    .push_tag   (tag_alloc),
    .has_free   (q_has_free),
    .pop        (serve),
    .pop_idx    (serve_idx),
    .q_valid    (q_valid),
    .q_write    (q_write),
    .q_bank     (q_bank),
    .q_row      (q_row),
    .q_col      (q_col),
    .q_wdata    (q_wdata),
    .q_tag      (q_tag),
    .q_wait     (q_wait),
    .q_older    (q_older),
    .q_dep      (q_dep)
  );

  for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
    logic here;
    assign here = (cmd_bank == BANK_BITS'(b));
    mc_bank u_bank (
      .clk      (clk),
      .rst_n    (rst_n),
      .do_act   (cmd == CMD_ACT && here),
      .do_pre   ((cmd == CMD_PRE && here) || (cmd == CMD_PREA && bank_open[b])),
      .do_rd    (cmd == CMD_RD && here),
      .do_wr    (cmd == CMD_WR && here),
      .act_row  (cmd_row),
      .is_open  (bank_open[b]),
      .open_row (bank_row[b]),
      .act_ok   (bank_act_ok[b]),
      .col_ok   (bank_col_ok[b]),
      .pre_ok   (bank_pre_ok[b])
    );
  end

  mc_chan u_chan (
    .clk    (clk),
    .rst_n  (rst_n),
    .do_act (cmd == CMD_ACT),
    .do_rd  (cmd == CMD_RD),
    .do_wr  (cmd == CMD_WR),
    .do_ref (cmd == CMD_REF),
    .act_ok (chan_act_ok),
    .rd_ok  (chan_rd_ok),
    .wr_ok  (chan_wr_ok),
    .any_ok (chan_any_ok)
  );

  mc_refresh #(.URGENT(REF_URGENT)) u_refresh (
    .clk    (clk),
    .rst_n  (rst_n),
    .idle   (q_valid == '0),
    .do_ref (cmd == CMD_REF),
    .hold   (ref_hold),
    .owed   (ref_owed)
  );

  mc_sched #(.DEPTH(DEPTH), .FR_FCFS(FR_FCFS), .STARVE_LIMIT(STARVE_LIMIT)) u_sched (
    .q_valid     (q_valid),
    .q_write     (q_write),
    .q_bank      (q_bank),
    .q_row       (q_row),
    .q_col       (q_col),
    .q_wait      (q_wait),
    .q_older     (q_older),
    .q_dep       (q_dep),
    .bank_open   (bank_open),
    .bank_row    (bank_row),
    .bank_act_ok (bank_act_ok),
    .bank_col_ok (bank_col_ok),
    .bank_pre_ok (bank_pre_ok),
    .chan_act_ok (chan_act_ok),
    .chan_rd_ok  (chan_rd_ok),
    .chan_wr_ok  (chan_wr_ok),
    .chan_any_ok (chan_any_ok),
    .rd_slot_ok  (rd_slot_ok),
    .ref_hold    (ref_hold),
    .cmd         (cmd),
    .cmd_bank    (cmd_bank),
    .cmd_row     (cmd_row),
    .cmd_col     (cmd_col),
    .serve       (serve),
    .serve_idx   (serve_idx)
  );

  mc_resp #(.RD_PIPE(RD_PIPE)) u_resp (
    .clk             (clk),
    .rst_n           (rst_n),
    .acc             (acc),
    .tag_alloc       (tag_alloc),
    .tag_free        (tag_free),
    .rd_issue        (cmd == CMD_RD),
    .wr_issue        (cmd == CMD_WR),
    .issue_tag       (q_tag[serve_idx]),
    .issue_wdata     (q_wdata[serve_idx]),
    .rd_slot_ok      (rd_slot_ok),
    .dram_wdata_en   (dram_wdata_en),
    .dram_wdata      (dram_wdata),
    .dram_data_valid (dram_data_valid),
    .dram_rdata      (dram_rdata),
    .rsp_valid       (rsp_valid),
    .rsp_ready       (rsp_ready),
    .rsp_rdata       (rsp_rdata)
  );

  assign dram_cmd  = cmd;
  assign dram_bank = cmd_bank;
  assign dram_row  = cmd_row;
  assign dram_col  = cmd_col;

  // Owed REFs are visible to waveforms and the testbench; the logic uses ref_hold.
  wire unused_owed = ^ref_owed;

endmodule
