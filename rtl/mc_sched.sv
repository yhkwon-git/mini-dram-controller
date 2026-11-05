// Command scheduler for the read queue (index 0) and the write queue (index 1).
// CMD_BUS = 2: one row command (ACT, PRE, PREA, REF, REFPB) and one column
// command (RD, WR) per cycle, on separate buses as in HBM. CMD_BUS = 1: one
// command per cycle (v3).
//
// Each queued request needs one next command:
//   RD/WR when its row is open (hit), ACT when its bank is closed (miss),
//   PRE when another row is open (conflict).
// It is ready when that command meets every bank and channel timing rule.
//
// Eligible requests: with WDRAIN = 1 the queue that wmode selects (reads or a
// write batch, see mc_wdrain); with WDRAIN = 0 both queues, oldest first
// across them as in v2 (w_older_r orders a read against a write).
//
// Picks:
//   column bus  the oldest ready RD/WR of the eligible queue, else of the
//               other queue (WDRAIN = 1)
//   row bus     a ready refresh command, then an RFM command (both below),
//               then the eligible queue's oldest ready ACT/PRE, then the other
//               queue's ACT, or PRE of a row nobody hits, on a bank the
//               eligible queue does not need (WDRAIN = 1), then a timer PRE
//               (PAGE_TIMER)
//   one bus     refresh, RFM, then the column pick before the row pick
//   (CMD_BUS=1) (FR_FCFS = 1) or the older of the two (FR_FCFS = 0)
//
// Row protection: a bank is not precharged while a queued request of either
// queue hits its row (FR_FCFS = 1), or an older one does (FR_FCFS = 0).
//
// Guards:
// - Same address: a write waits until every older write to its address has
//   issued (q_dep). Reads need no order among themselves, and mem_ctrl keeps
//   a read and a write to one address from being queued at the same time.
// - Starvation: once the oldest eligible request has waited STARVE_LIMIT
//   cycles, selection becomes oldest-first and, if it needs a PRE, its bank
//   stops serving younger hits. w_starve tells mc_wdrain that a write has.
//
// Page policy:
// - PAGE_CLOSE: a RD/WR carries auto-precharge unless another queued request
//   (either queue) hits the same row.
// - PAGE_TIMER: when nothing else is ready, PRE an open bank that no queued
//   request needs and that has had no ACT/RD/WR for PAGE_TIMEOUT cycles.
//
// "Oldest" comes from the age matrices: the oldest member of a set is the one
// that no other member is older than, an AND-OR over the set. The pick stays
// one-hot all the way out (serve, and AND-OR selects for the command fields),
// so no index is encoded here and decoded again downstream.
//
// Bank groups: column and ACT readiness come per group from mc_chan
// (tCCD_S/L, tRRD_S/L, tWTR_S/L).
//
// Two buses: both picks issue on one edge, except that a PRE never goes to a
// bank that has a column command ready (FCFS could otherwise pair a PRE for
// an old conflict with a younger hit's RD on the same bank).
//
// Refresh (ref_hold), REF_ALL: no ACT and no RD/WR on any bank; PREA once
// every open bank may precharge, then REF once every bank has met tRP and tRC.
// REF_BANK: the same for bank ref_bank only, with PRE and REFpb; the other
// banks keep working. A ready refresh command goes first on the row bus.
//
// Refresh management (RFM): a bank at RAA_MMT takes no ACT; it gets a REFpb
// as soon as it is closed (PRE first once no queued request hits its row).
// With RFM_EARLY, a bank at RAA_IMT that no queued request needs also gets a
// REFpb when it is closed. These come after the periodic refresh on the row
// bus.
`timescale 1ns/1ps

module mc_sched
  import dram_pkg::*;
#(
  parameter int DEPTH        = QUEUE_DEPTH,
  parameter bit FR_FCFS      = 1'b1,
  parameter bit WDRAIN       = 1'b1,
  parameter int PAGE_POLICY  = PAGE_OPEN,
  parameter int CMD_BUS      = 2,
  parameter int REF_MODE     = REF_BANK,
  parameter bit RFM_EARLY    = 1'b1,
  parameter int STARVE_LIMIT = 160
) (
  input  logic [1:0][DEPTH-1:0]                 q_valid,
  input  logic [1:0][DEPTH-1:0][BANK_BITS-1:0]  q_bank,
  input  logic [1:0][DEPTH-1:0][ROW_BITS-1:0]   q_row,
  input  logic [1:0][DEPTH-1:0][COL_BITS-1:0]   q_col,
  input  logic [1:0][DEPTH-1:0][7:0]            q_wait,
  input  logic [1:0][DEPTH-1:0][DEPTH-1:0]      q_older,
  input  logic [1:0][DEPTH-1:0][DEPTH-1:0]      q_dep,
  input  logic [DEPTH-1:0][DEPTH-1:0]           w_older_r,  // [w][r]: write w before read r
  input  logic                                  wmode,
  input  logic [NUM_BANKS-1:0]                  bank_open,
  input  logic [NUM_BANKS-1:0][ROW_BITS-1:0]    bank_row,
  input  logic [NUM_BANKS-1:0]                  bank_act_ok,
  input  logic [NUM_BANKS-1:0]                  bank_col_ok,
  input  logic [NUM_BANKS-1:0]                  bank_pre_ok,
  input  logic [NUM_BANKS-1:0]                  bank_idle,
  input  logic [NUM_BANKS-1:0]                  bank_raa_imt,
  input  logic [NUM_BANKS-1:0]                  bank_raa_mmt,
  input  logic [NUM_BG-1:0]                     chan_act_ok,
  input  logic [NUM_BG-1:0]                     chan_rd_ok,
  input  logic [NUM_BG-1:0]                     chan_wr_ok,
  input  logic                                  chan_refpb_ok,
  input  logic                                  chan_any_ok,
  input  logic                                  rd_slot_ok,
  input  logic                                  ref_hold,
  input  logic [BANK_BITS-1:0]                  ref_bank,   // REF_BANK: the bank to refresh
  output dram_cmd_e                             rcmd,       // row bus
  output logic [BANK_BITS-1:0]                  rbank,
  output logic [ROW_BITS-1:0]                   rrow,
  output dram_cmd_e                             ccmd,       // column bus
  output logic [BANK_BITS-1:0]                  cbank,
  output logic [COL_BITS-1:0]                   ccol,
  output logic                                  cap,        // RD/WR with auto-precharge
  output logic [1:0][DEPTH-1:0]                 serve,      // one-hot: ccmd is this entry's RD/WR
  output logic [NUM_BANKS-1:0]                  wanted,     // banks a queued request needs
  output logic                                  ref_issued, // rcmd is the periodic REF/REFpb
  output logic                                  w_starve
);

  typedef logic [1:0][DEPTH-1:0] set_t;

  set_t                 live, hit, conf, miss, hazard, waited, guarded, other_hit;
  set_t                 col_rdy, row_rdy, prep_rdy, xcol_rdy, ccand, rcand, old_sel, col_sel, row_sel;
  logic [1:0]           elig;
  logic [NUM_BANKS-1:0] hit_bank, live_wanted, starve_bank, tpre_rdy, blocked, col_bank_rdy;
  logic                 starving, col_first, use_col, col_wr, row_act, keep_row;
  logic                 ref_go;    // a refresh command is ready this cycle
  dram_cmd_e            ref_cmd;
  logic [BANK_BITS-1:0] ref_cbank;
  logic                 rfm_go;    // an RFM command (PRE or REFpb) is ready
  dram_cmd_e            rfm_cmd;
  logic [BANK_BITS-1:0] rfm_bank;
  logic [BANK_BITS-1:0] col_bank, row_bank;
  logic [ROW_BITS-1:0]  row_row;
  logic [COL_BITS-1:0]  col_col;
  logic [BANK_BITS-1:0] tpre_bank;

  // Entry (qa, ia) was accepted before entry (qb, ib)
  function automatic logic older(input int qa, input int ia, input int qb, input int ib);
    if (qa == qb) return q_older[qa][ia][ib];
    if (qa == 1)  return w_older_r[ia][ib];
    return !w_older_r[ib][ia];
  endfunction

  // One-hot: the member of m that no other member of m is older than (one queue)
  function automatic logic [DEPTH-1:0] oldest_in(input logic [DEPTH-1:0] m,
                                                 input logic [DEPTH-1:0][DEPTH-1:0] old);
    logic [DEPTH-1:0] r;
    for (int i = 0; i < DEPTH; i++) begin
      r[i] = m[i];
      for (int j = 0; j < DEPTH; j++)
        if (j != i && m[j] && old[j][i]) r[i] = 1'b0;
    end
    return r;
  endfunction

  // Oldest member of a set that spans both queues: the oldest of each queue,
  // then the older of the two. With WDRAIN only one queue is eligible at a time.
  function automatic set_t oldest2(input set_t m);
    set_t r;
    logic w_first;
    r[0] = oldest_in(m[0], q_older[0]);
    r[1] = oldest_in(m[1], q_older[1]);
    if (!WDRAIN) begin
      w_first = 1'b0;
      for (int w = 0; w < DEPTH; w++)
        for (int k = 0; k < DEPTH; k++)
          if (r[1][w] && r[0][k] && w_older_r[w][k]) w_first = 1'b1;
      if (r[0] != '0 && r[1] != '0) begin
        if (w_first) r[0] = '0;
        else         r[1] = '0;
      end
    end
    return r;
  endfunction


  // Banks a queued request needs (also read by mc_refresh, so kept apart from
  // the logic below, which depends on ref_hold)
  always_comb begin
    wanted = '0;
    for (int q = 0; q < 2; q++)
      for (int i = 0; i < DEPTH; i++)
        if (q_valid[q][i]) wanted[q_bank[q][i]] = 1'b1;
  end

  always_comb begin
    elig[0] = !WDRAIN || !wmode;
    elig[1] = !WDRAIN ||  wmode;
    hit_bank      = '0;
    live_wanted   = '0;
    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        hit[q][i]    = q_valid[q][i] &&  bank_open[q_bank[q][i]] && (bank_row[q_bank[q][i]] == q_row[q][i]);
        conf[q][i]   = q_valid[q][i] &&  bank_open[q_bank[q][i]] && (bank_row[q_bank[q][i]] != q_row[q][i]);
        miss[q][i]   = q_valid[q][i] && !bank_open[q_bank[q][i]];
        hazard[q][i] = |(q_dep[q][i] & q_valid[q]);
        waited[q][i] = q_wait[q][i] >= 8'(STARVE_LIMIT);
        live[q][i]   = q_valid[q][i] && elig[q];
        if (hit[q][i])             hit_bank[q_bank[q][i]]      = 1'b1;
        if (live[q][i])            live_wanted[q_bank[q][i]]   = 1'b1;
      end
    end

    // A hit on the same bank keeps the row open: any eligible hit for FR-FCFS,
    // an older eligible one for FCFS. other_hit: another request hits the row.
    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        guarded[q][i]   = FR_FCFS ? hit_bank[q_bank[q][i]] : 1'b0;
        other_hit[q][i] = 1'b0;
        for (int p = 0; p < 2; p++) begin
          for (int j = 0; j < DEPTH; j++) begin
            if (!FR_FCFS && hit[p][j] && q_bank[p][j] == q_bank[q][i] && older(p, j, q, i))
              guarded[q][i] = 1'b1;
            if (PAGE_POLICY == PAGE_CLOSE && !(p == q && j == i) && hit[p][j] &&
                q_bank[p][j] == q_bank[q][i])
              other_hit[q][i] = 1'b1;
          end
        end
      end
    end

    old_sel     = oldest2(live);
    starving    = |(old_sel & waited);
    w_starve    = |(q_valid[1] & waited[1]);
    starve_bank = '0;
    for (int q = 0; q < 2; q++)
      for (int i = 0; i < DEPTH; i++)
        if (starving && old_sel[q][i] && conf[q][i]) starve_bank[q_bank[q][i]] = 1'b1;

    // Banks closed to traffic by refresh: all of them (REF_ALL) or one (REF_BANK)
    for (int b = 0; b < NUM_BANKS; b++)
      blocked[b] = ref_hold && (REF_MODE == REF_ALL || ref_bank == BANK_BITS'(b));

    // Column commands first: a PRE on the row bus must not meet one on its bank
    col_bank_rdy = '0;
    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        col_rdy[q][i]  = live[q][i] && hit[q][i] && !hazard[q][i] && !blocked[q_bank[q][i]] &&
                         bank_col_ok[q_bank[q][i]] && !starve_bank[q_bank[q][i]] &&
                         ((q == 1) ? chan_wr_ok[bg_of(q_bank[q][i])]
                                   : (chan_rd_ok[bg_of(q_bank[q][i])] && rd_slot_ok));
        // The waiting queue may use a slot the eligible one leaves empty
        xcol_rdy[q][i] = WDRAIN && q_valid[q][i] && !elig[q] && hit[q][i] && !hazard[q][i] &&
                         !blocked[q_bank[q][i]] && bank_col_ok[q_bank[q][i]] &&
                         !starve_bank[q_bank[q][i]] &&
                         ((q == 1) ? chan_wr_ok[bg_of(q_bank[q][i])]
                                   : (chan_rd_ok[bg_of(q_bank[q][i])] && rd_slot_ok));
        if (CMD_BUS == 2 && (col_rdy[q][i] || xcol_rdy[q][i])) col_bank_rdy[q_bank[q][i]] = 1'b1;
      end
    end

    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        row_rdy[q][i]  = live[q][i] && !blocked[q_bank[q][i]] && (
                           (miss[q][i] && bank_act_ok[q_bank[q][i]] && !bank_raa_mmt[q_bank[q][i]] &&
                            chan_act_ok[bg_of(q_bank[q][i])]) ||
                           (conf[q][i] && bank_pre_ok[q_bank[q][i]] && chan_any_ok &&
                            !col_bank_rdy[q_bank[q][i]] &&
                            (!guarded[q][i] || starve_bank[q_bank[q][i]])));
        prep_rdy[q][i] = WDRAIN && q_valid[q][i] && !elig[q] && !blocked[q_bank[q][i]] &&
                         !live_wanted[q_bank[q][i]] && (
                           (miss[q][i] && bank_act_ok[q_bank[q][i]] && !bank_raa_mmt[q_bank[q][i]] &&
                            chan_act_ok[bg_of(q_bank[q][i])]) ||
                           (conf[q][i] && bank_pre_ok[q_bank[q][i]] && chan_any_ok &&
                            !col_bank_rdy[q_bank[q][i]] && !hit_bank[q_bank[q][i]]));
      end
    end

    // One column and one row candidate set: the eligible queue's, or the
    // other queue's when the eligible one has none ready.
    ccand     = (|col_rdy) ? col_rdy : xcol_rdy;
    rcand     = (|row_rdy) ? row_rdy : prep_rdy;
    col_sel   = oldest2(ccand);
    row_sel   = oldest2(rcand);
    col_first = 1'b0;
    for (int qa = 0; qa < 2; qa++)
      for (int ia = 0; ia < DEPTH; ia++)
        for (int qb = 0; qb < 2; qb++)
          for (int ib = 0; ib < DEPTH; ib++)
            if ((qa == qb || !WDRAIN) && col_sel[qa][ia] && row_sel[qb][ib] && older(qa, ia, qb, ib))
              col_first = 1'b1;
    // Priority: eligible RD/WR (FR-FCFS), eligible ACT/PRE, the other queue's
    // RD/WR, then its ACT/PRE. FCFS orders the eligible pair by age.
    if (|col_rdy)
      use_col = (FR_FCFS && !starving) || !(|row_rdy) || col_first;
    else
      use_col = |xcol_rdy && !(|row_rdy);
    keep_row = |(col_sel & other_hit);
    col_wr   = |col_sel[1];
    row_act  = |(row_sel & miss);
    col_bank = '0;
    col_col  = '0;
    row_bank = '0;
    row_row  = '0;
    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        col_bank = col_bank | ({BANK_BITS{col_sel[q][i]}} & q_bank[q][i]);
        col_col  = col_col  | ({COL_BITS{col_sel[q][i]}}  & q_col[q][i]);
        row_bank = row_bank | ({BANK_BITS{row_sel[q][i]}} & q_bank[q][i]);
        row_row  = row_row  | ({ROW_BITS{row_sel[q][i]}}  & q_row[q][i]);
      end
    end

    tpre_rdy  = '0;
    tpre_bank = '0;
    if (PAGE_POLICY == PAGE_TIMER) begin
      for (int b = NUM_BANKS - 1; b >= 0; b--) begin
        tpre_rdy[b] = bank_open[b] && bank_idle[b] && !wanted[b] && bank_pre_ok[b] &&
                      chan_any_ok && !blocked[b];
        if (tpre_rdy[b]) tpre_bank = BANK_BITS'(b);
      end
    end

    // Refresh: PREA then REF for all banks, or PRE then REFpb for ref_bank
    ref_go    = 1'b0;
    ref_cmd   = CMD_NOP;
    ref_cbank = '0;
    if (ref_hold) begin
      if (REF_MODE == REF_ALL) begin
        if (|bank_open) begin
          ref_go  = chan_any_ok && ((bank_pre_ok | ~bank_open) == '1);
          ref_cmd = CMD_PREA;
        end else begin
          ref_go  = chan_any_ok && (bank_act_ok == '1);
          ref_cmd = CMD_REF;
        end
      end else begin
        ref_cbank = ref_bank;
        if (bank_open[ref_bank]) begin
          ref_go  = chan_any_ok && bank_pre_ok[ref_bank];
          ref_cmd = CMD_PRE;
        end else begin
          ref_go  = chan_refpb_ok && bank_act_ok[ref_bank];
          ref_cmd = CMD_REFPB;
        end
      end
    end

    // RFM: a bank at RAA_MMT first (PRE once nothing hits its row), then an
    // idle closed bank at RAA_IMT. The lowest such bank number goes first.
    rfm_go   = 1'b0;
    rfm_cmd  = CMD_NOP;
    rfm_bank = '0;
    for (int b = NUM_BANKS - 1; b >= 0; b--) begin
      if (!blocked[b] && bank_raa_imt[b] && (bank_raa_mmt[b] || (RFM_EARLY && !wanted[b])) &&
          !bank_open[b] &&
          bank_act_ok[b] && chan_refpb_ok) begin
        rfm_go   = 1'b1;
        rfm_cmd  = CMD_REFPB;
        rfm_bank = BANK_BITS'(b);
      end
    end
    for (int b = NUM_BANKS - 1; b >= 0; b--) begin
      if (!blocked[b] && bank_raa_mmt[b] && bank_open[b] && !hit_bank[b] && bank_pre_ok[b] &&
          chan_any_ok && !col_bank_rdy[b]) begin
        rfm_go   = 1'b1;
        rfm_cmd  = CMD_PRE;
        rfm_bank = BANK_BITS'(b);
      end
    end
  end

  // Output stage. Two buses: the column pick and the row pick (refresh first)
  // go out together. One bus: refresh, then the column or row pick (use_col).
  always_comb begin
    rcmd       = CMD_NOP;
    rbank      = '0;
    rrow       = '0;
    ccmd       = CMD_NOP;
    cbank      = '0;
    ccol       = '0;
    cap        = 1'b0;
    serve      = '0;
    ref_issued = 1'b0;
    if (CMD_BUS == 2 ? |ccand : (!ref_go && !rfm_go && use_col)) begin
      ccmd  = col_wr ? CMD_WR : CMD_RD;
      cbank = col_bank;
      ccol  = col_col;
      cap   = (PAGE_POLICY == PAGE_CLOSE) && !keep_row;
      serve = col_sel;
    end
    if (ref_go) begin
      rcmd       = ref_cmd;
      rbank      = ref_cbank;
      ref_issued = (ref_cmd == CMD_REF || ref_cmd == CMD_REFPB);
    end else if (rfm_go) begin
      rcmd  = rfm_cmd;
      rbank = rfm_bank;
    end else if (CMD_BUS == 2 || !use_col) begin
      if (|rcand) begin
        rcmd  = row_act ? CMD_ACT : CMD_PRE;
        rbank = row_bank;
        rrow  = row_row;
      end else if (|tpre_rdy) begin
        rcmd  = CMD_PRE;
        rbank = tpre_bank;
      end
    end
  end

endmodule
