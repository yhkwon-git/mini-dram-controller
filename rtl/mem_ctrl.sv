// Mini memory controller v4: read and write queues, command-level scheduler,
// separate row and column command buses, bank groups, per-bank refresh.
//
//   mc_queue x2  accepted reads and writes until their RD/WR is issued
//   mc_xage      age between the two queues
//   mc_wdrain    read mode / write batch (watermarks)
//   mc_bank x4   open row and same-bank timing (tRCD tRP tRAS tRC tRTP tWR),
//                auto-precharge, idle time
//   mc_chan      channel timing per bank group (tCCD_S/L tRRD_S/L tWTR_S/L
//                tFAW tRTW tRFC)
//   mc_refresh   refresh owed per tREFI (all-bank) or per tREFI/4 (per-bank)
//   mc_sched     a row command and a column command per cycle (FR-FCFS or
//                FCFS, page policy, refresh)
//   mc_resp      tags, read-return FIFO, write-data pipeline, in-order responses
//
// The DRAM side is DFI-like: a row command bus (ACT, PRE, PREA, REF, REFPB)
// and a column command bus (RD, WR with auto-precharge), write data a fixed WL
// after its WR, read data back on data_valid in RD order (RL after the RD with
// this repo's DRAM model; a PHY may take longer, the count of RDs in flight is
// what matters), and no busy signal; the controller tracks every timing rule
// itself. The column bus carries no row: the device uses the open one.
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
  parameter int CMD_BUS      = 2,            // 2 = row + column bus, 1 = one command per cycle (v3)
  parameter int REF_MODE     = REF_BANK,     // REF_BANK = per-bank REFpb, REF_ALL = PREA + REF (v3)
  parameter bit RFM_EARLY    = 1'b1,         // RFM at RAA_IMT for idle banks; 0 = only at RAA_MMT
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

  output dram_cmd_e            dram_rcmd,   // row bus: ACT, PRE, PREA, REF, REFPB
  output logic [BANK_BITS-1:0] dram_rbank,
  output logic [ROW_BITS-1:0]  dram_row,
  output dram_cmd_e            dram_ccmd,   // column bus: RD, WR
  output logic [BANK_BITS-1:0] dram_cbank,
  output logic [COL_BITS-1:0]  dram_col,
  output logic                 dram_ap,     // auto-precharge with this RD/WR
  output logic                 dram_wdata_en,
  output logic [DATA_BITS-1:0] dram_wdata,
  input  logic                 dram_data_valid,
  input  logic [DATA_BITS-1:0] dram_rdata,

  // Both request queues are empty: every accepted request has reached the
  // DRAM bus or was answered from the write queue. A test engine on the PHY
  // side can wait for it before reading back what it wrote.
  output logic                 q_empty
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
  logic [NUM_BANKS-1:0]                bank_raa_imt, bank_raa_mmt;
  logic                                ref_issued;
  logic [NUM_BANKS-1:0][ROW_BITS-1:0]  bank_row;
  logic [NUM_BG-1:0]                   chan_act_ok, chan_rd_ok, chan_wr_ok;
  logic                                chan_refpb_ok, chan_any_ok;
  logic                                ref_hold;
  logic [BANK_BITS-1:0]                ref_bank;
  logic [3:0]                          ref_owed;
  logic [NUM_BANKS-1:0]                wanted;

  dram_cmd_e                       rcmd, ccmd;
  logic [BANK_BITS-1:0]            rbank, cbank;
  logic [ROW_BITS-1:0]             rrow;
  logic [COL_BITS-1:0]             ccol;
  logic                            cap;
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
  assign q_empty   = (q_valid == '0);
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
    logic row_here, col_here;
    assign row_here = (int'(rbank) == b);
    assign col_here = (int'(cbank) == b);
    mc_bank #(.PAGE_TIMEOUT(PAGE_TIMEOUT)) u_bank (
      .clk       (clk),
      .rst_n     (rst_n),
      .do_act    (rcmd == CMD_ACT && row_here),
      .do_pre    ((rcmd == CMD_PRE && row_here) || (rcmd == CMD_PREA && bank_open[b])),
      .do_rd     (ccmd == CMD_RD && col_here),
      .do_wr     (ccmd == CMD_WR && col_here),
      .do_ap     (cap),
      .do_refpb  (rcmd == CMD_REFPB && row_here),
      .do_ref    (rcmd == CMD_REF),
      .act_row   (rrow),
      .is_open   (bank_open[b]),
      .open_row  (bank_row[b]),
      .act_ok    (bank_act_ok[b]),
      .col_ok    (bank_col_ok[b]),
      .pre_ok    (bank_pre_ok[b]),
      .idle_long (bank_idle[b]),
      .raa_imt   (bank_raa_imt[b]),
      .raa_mmt   (bank_raa_mmt[b])
    );
  end

  mc_chan u_chan (
    .clk      (clk),
    .rst_n    (rst_n),
    .do_act   (rcmd == CMD_ACT),
    .do_refpb (rcmd == CMD_REFPB),
    .row_bg   (bg_of(rbank)),
    .do_rd    (ccmd == CMD_RD),
    .do_wr    (ccmd == CMD_WR),
    .col_bg   (bg_of(cbank)),
    .do_ref   (rcmd == CMD_REF),
    .act_ok   (chan_act_ok),
    .rd_ok    (chan_rd_ok),
    .wr_ok    (chan_wr_ok),
    .refpb_ok (chan_refpb_ok),
    .any_ok   (chan_any_ok)
  );

  mc_refresh #(.URGENT(REF_URGENT), .MODE(REF_MODE)) u_refresh (
    .clk    (clk),
    .rst_n  (rst_n),
    .idle   (q_valid == '0),
    .wanted (wanted),
    .do_ref (ref_issued),
    .hold   (ref_hold),
    .bank   (ref_bank),
    .owed   (ref_owed)
  );

  mc_sched #(
    .DEPTH        (DEPTH),
    .FR_FCFS      (FR_FCFS),
    .WDRAIN       (WDRAIN),
    .PAGE_POLICY  (PAGE_POLICY),
    .CMD_BUS      (CMD_BUS),
    .REF_MODE     (REF_MODE),
    .RFM_EARLY    (RFM_EARLY),
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
    .bank_raa_imt (bank_raa_imt),
    .bank_raa_mmt (bank_raa_mmt),
    .chan_act_ok (chan_act_ok),
    .chan_rd_ok  (chan_rd_ok),
    .chan_wr_ok  (chan_wr_ok),
    .chan_refpb_ok (chan_refpb_ok),
    .chan_any_ok (chan_any_ok),
    .rd_slot_ok  (rd_slot_ok),
    .ref_hold    (ref_hold),
    .ref_bank    (ref_bank),
    .rcmd        (rcmd),
    .rbank       (rbank),
    .rrow        (rrow),
    .ccmd        (ccmd),
    .cbank       (cbank),
    .ccol        (ccol),
    .cap         (cap),
    .serve       (serve),
    .wanted      (wanted),
    .ref_issued  (ref_issued),
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
    .rd_issue        (ccmd == CMD_RD),
    .wr_issue        (ccmd == CMD_WR),
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

  assign dram_rcmd  = rcmd;
  assign dram_rbank = rbank;
  assign dram_row   = rrow;
  assign dram_ccmd  = ccmd;
  assign dram_cbank = cbank;
  assign dram_col   = ccol;
  assign dram_ap    = cap;

  // Owed REFs are visible to waveforms and the testbench; the logic uses
  // ref_hold. Reads carry no data and writes need no tag (posted).
  wire unused = ^{ref_owed, q_wdata[0], q_tag[1]};

endmodule
