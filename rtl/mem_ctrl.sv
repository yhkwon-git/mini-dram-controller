// Mini memory controller v3: read and write queues + command-level scheduler.
//
//   mc_queue x2  accepted reads and writes until their RD/WR is issued
//   mc_xage      age between the two queues
//   mc_wdrain    read mode / write batch (watermarks)
//   mc_bank x4   open row and same-bank timing (tRCD tRP tRAS tRC tRTP tWR),
//                auto-precharge, idle time
//   mc_chan      channel timing (tCCD tRRD tFAW tWTR tRTW tRFC)
//   mc_refresh   one REF owed per tREFI, paid back when idle or when urgent
//   mc_sched     one DRAM command per cycle (FR-FCFS or FCFS, page policy)
//   mc_resp      tags, read-return FIFO, write-data pipeline, in-order responses
//
// The DRAM side is DFI-like: commands with fixed data latencies (RL, WL) and
// no busy signal; the controller tracks every timing rule itself.
//
// Writes are posted: answered when accepted. A read whose address is in the
// write queue is answered from the youngest such write (forwarding) and never
// reaches the DRAM. A write whose address is in the read queue is held on the
// host port until that read has issued, so the read cannot see it.
`timescale 1ns/1ps

module mem_ctrl
  import dram_pkg::*;
#(
  parameter int DEPTH        = QUEUE_DEPTH,  // entries per queue (reads, writes)
  parameter bit FR_FCFS      = 1'b1,         // 0 = oldest ready command first
  parameter bit WDRAIN       = 1'b1,         // 0 = reads and writes compete oldest-first (v2)
  parameter int WR_HI        = 6,            // write batch starts at this many queued writes
  parameter int WR_LO        = 2,            // ... and ends at this many
  parameter int PAGE_POLICY  = PAGE_OPEN,    // PAGE_OPEN, PAGE_CLOSE, PAGE_TIMER
  parameter int PAGE_TIMEOUT = 16,           // PAGE_TIMER: idle cycles before a PRE
  parameter int ADDR_MAP     = MAP_XOR,      // MAP_XOR, MAP_RBC, MAP_RCB, MAP_BRC (v2)
  parameter int RD_PIPE      = 4,            // RDs in flight on the DRAM bus (v1: 1)
  parameter int STARVE_LIMIT = 160,          // cycles before the oldest request overrides row hits
  parameter int REF_URGENT   = 4             // owed REFs that stop new traffic
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
  output logic                 dram_ap,     // auto-precharge with this RD/WR
  output logic                 dram_wdata_en,
  output logic [DATA_BITS-1:0] dram_wdata,
  input  logic                 dram_data_valid,
  input  logic [DATA_BITS-1:0] dram_rdata
);

  localparam int AW = $clog2(DEPTH);

  logic                            acc, collide, fwd;
  logic [TAG_BITS-1:0]             issue_tag;
  logic [DATA_BITS-1:0]            issue_wdata;
  logic [DEPTH-1:0]                fwd_sel;
  logic [DATA_BITS-1:0]            fwd_data;
  logic [BANK_BITS-1:0]            req_bank;
  logic [ROW_BITS-1:0]             req_row;
  logic [COL_BITS-1:0]             req_col;

  // [0] read queue, [1] write queue
  logic [1:0]                            q_has_free, q_push;
  logic [1:0][AW-1:0]                    q_free;
  logic [1:0][DEPTH-1:0]                 q_match, q_valid;
  logic [1:0][DEPTH-1:0][BANK_BITS-1:0]  q_bank;
  logic [1:0][DEPTH-1:0][ROW_BITS-1:0]   q_row;
  logic [1:0][DEPTH-1:0][COL_BITS-1:0]   q_col;
  logic [1:0][DEPTH-1:0][DATA_BITS-1:0]  q_wdata;
  logic [1:0][DEPTH-1:0][TAG_BITS-1:0]   q_tag;
  logic [1:0][DEPTH-1:0][7:0]            q_wait;
  logic [1:0][DEPTH-1:0][DEPTH-1:0]      q_older, q_dep;
  logic [DEPTH-1:0][DEPTH-1:0]           w_older_r;
  logic                                  wmode, w_starve;

  logic [TAG_BITS-1:0]             tag_alloc;
  logic                            tag_free, rd_slot_ok;

  logic [NUM_BANKS-1:0]                bank_open, bank_act_ok, bank_col_ok, bank_pre_ok, bank_idle;
  logic [NUM_BANKS-1:0][ROW_BITS-1:0]  bank_row;
  logic                                chan_act_ok, chan_rd_ok, chan_wr_ok, chan_any_ok;
  logic                                ref_hold;
  logic [3:0]                          ref_owed;

  dram_cmd_e                       cmd;
  logic [BANK_BITS-1:0]            cmd_bank;
  logic [ROW_BITS-1:0]             cmd_row;
  logic [COL_BITS-1:0]             cmd_col;
  logic                            cmd_ap;
  logic [1:0][DEPTH-1:0]           serve;  // one-hot entry whose RD/WR issues

  assign req_bank  = map_bank(req_addr, ADDR_MAP);
  assign req_row   = map_row(req_addr, ADDR_MAP);
  assign req_col   = map_col(req_addr, ADDR_MAP);

  // A read forwarded from the write queue needs no read-queue entry. A write
  // waits while the read queue holds its address.
  assign fwd       = !req_write && |q_match[1];
  assign collide   =  req_write && |q_match[0];
  assign req_ready = tag_free && (fwd || q_has_free[req_write]) && !collide;
  assign acc       = req_valid && req_ready;
  assign q_push    = {acc && req_write, acc && !req_write && !fwd};
  assign rsp_err   = 1'b0;

  // Youngest queued write to the read address: no other match is younger
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      fwd_sel[i] = q_match[1][i];
      for (int j = 0; j < DEPTH; j++)
        if (j != i && q_match[1][j] && q_older[1][i][j]) fwd_sel[i] = 1'b0;
    end
    fwd_data = '0;
    for (int i = 0; i < DEPTH; i++)
      if (fwd_sel[i]) fwd_data = fwd_data | q_wdata[1][i];
  end

  // Tag of the read and data of the write that issue now (one-hot selects)
  always_comb begin
    issue_tag   = '0;
    issue_wdata = '0;
    for (int i = 0; i < DEPTH; i++) begin
      issue_tag   = issue_tag   | ({TAG_BITS{serve[0][i]}}  & q_tag[0][i]);
      issue_wdata = issue_wdata | ({DATA_BITS{serve[1][i]}} & q_wdata[1][i]);
    end
  end

  for (genvar q = 0; q < 2; q++) begin : g_q
    mc_queue #(.DEPTH(DEPTH), .ORDERED(q == 1)) u_queue (
      .clk        (clk),
      .rst_n      (rst_n),
      .push       (q_push[q]),
      .push_bank  (req_bank),
      .push_row   (req_row),
      .push_col   (req_col),
      .push_wdata (req_wdata),
      .push_tag   (tag_alloc),
      .has_free   (q_has_free[q]),
      .free_idx   (q_free[q]),
      .match      (q_match[q]),
      .pop        (serve[q]),
      .q_valid    (q_valid[q]),
      .q_bank     (q_bank[q]),
      .q_row      (q_row[q]),
      .q_col      (q_col[q]),
      .q_wdata    (q_wdata[q]),
      .q_tag      (q_tag[q]),
      .q_wait     (q_wait[q]),
      .q_older    (q_older[q]),
      .q_dep      (q_dep[q])
    );
  end

  mc_xage #(.DEPTH(DEPTH)) u_xage (
    .clk       (clk),
    .rst_n     (rst_n),
    .push_rd   (q_push[0]),
    .push_wr   (q_push[1]),
    .slot      (q_free[req_write]),
    .wq_valid  (q_valid[1]),
    .w_older_r (w_older_r)
  );

  mc_wdrain #(.DEPTH(DEPTH), .WR_HI(WR_HI), .WR_LO(WR_LO)) u_wdrain (
    .clk      (clk),
    .rst_n    (rst_n),
    .rq_valid (q_valid[0]),
    .wq_valid (q_valid[1]),
    .w_starve (w_starve),
    .wmode    (wmode)
  );

  for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
    logic here;
    assign here = (cmd_bank == BANK_BITS'(b));
    mc_bank #(.PAGE_TIMEOUT(PAGE_TIMEOUT)) u_bank (
      .clk       (clk),
      .rst_n     (rst_n),
      .do_act    (cmd == CMD_ACT && here),
      .do_pre    ((cmd == CMD_PRE && here) || (cmd == CMD_PREA && bank_open[b])),
      .do_rd     (cmd == CMD_RD && here),
      .do_wr     (cmd == CMD_WR && here),
      .do_ap     (cmd_ap),
      .act_row   (cmd_row),
      .is_open   (bank_open[b]),
      .open_row  (bank_row[b]),
      .act_ok    (bank_act_ok[b]),
      .col_ok    (bank_col_ok[b]),
      .pre_ok    (bank_pre_ok[b]),
      .idle_long (bank_idle[b])
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

  mc_sched #(
    .DEPTH        (DEPTH),
    .FR_FCFS      (FR_FCFS),
    .WDRAIN       (WDRAIN),
    .PAGE_POLICY  (PAGE_POLICY),
    .STARVE_LIMIT (STARVE_LIMIT)
  ) u_sched (
    .q_valid     (q_valid),
    .q_bank      (q_bank),
    .q_row       (q_row),
    .q_col       (q_col),
    .q_wait      (q_wait),
    .q_older     (q_older),
    .q_dep       (q_dep),
    .w_older_r   (w_older_r),
    .wmode       (wmode),
    .bank_open   (bank_open),
    .bank_row    (bank_row),
    .bank_act_ok (bank_act_ok),
    .bank_col_ok (bank_col_ok),
    .bank_pre_ok (bank_pre_ok),
    .bank_idle   (bank_idle),
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
    .cmd_ap      (cmd_ap),
    .serve       (serve),
    .w_starve    (w_starve)
  );

  mc_resp #(.RD_PIPE(RD_PIPE)) u_resp (
    .clk             (clk),
    .rst_n           (rst_n),
    .acc             (acc),
    .acc_write       (req_write),
    .acc_fwd         (fwd),
    .fwd_data        (fwd_data),
    .tag_alloc       (tag_alloc),
    .tag_free        (tag_free),
    .rd_issue        (cmd == CMD_RD),
    .wr_issue        (cmd == CMD_WR),
    .issue_tag       (issue_tag),
    .issue_wdata     (issue_wdata),
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
  assign dram_ap   = cmd_ap;

  // Owed REFs are visible to waveforms and the testbench; the logic uses
  // ref_hold. Reads carry no data and writes need no tag (posted).
  wire unused = ^{ref_owed, q_wdata[0], q_tag[1]};

endmodule
