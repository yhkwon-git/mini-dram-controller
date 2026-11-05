// Command scheduler: picks at most one DRAM command per cycle from the read
// queue (index 0) and the write queue (index 1).
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
// Pick, in order:
//   1. the oldest ready RD/WR of the eligible queue
//   2. its oldest ready ACT/PRE
//   3. the other queue's oldest ready RD/WR             (WDRAIN = 1)
//   4. the other queue's ACT, or PRE of a row nobody hits, on a bank the
//      eligible queue does not need                     (WDRAIN = 1)
//   5. a timer PRE                                      (PAGE_TIMER)
// FR_FCFS = 0 orders 1 and 2 by age instead of putting 1 first.
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
// Refresh (ref_hold): no ACT and no RD/WR. PREA once every open bank may
// precharge, then REF once every bank has met tRP and tRC.
`timescale 1ns/1ps

module mc_sched
  import dram_pkg::*;
#(
  parameter int DEPTH        = QUEUE_DEPTH,
  parameter bit FR_FCFS      = 1'b1,
  parameter bit WDRAIN       = 1'b1,
  parameter int PAGE_POLICY  = PAGE_OPEN,
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
  input  logic                                  chan_act_ok,
  input  logic                                  chan_rd_ok,
  input  logic                                  chan_wr_ok,
  input  logic                                  chan_any_ok,
  input  logic                                  rd_slot_ok,
  input  logic                                  ref_hold,
  output dram_cmd_e                             cmd,
  output logic [BANK_BITS-1:0]                  cmd_bank,
  output logic [ROW_BITS-1:0]                   cmd_row,
  output logic [COL_BITS-1:0]                   cmd_col,
  output logic                                  cmd_ap,     // RD/WR with auto-precharge
  output logic [1:0][DEPTH-1:0]                 serve,      // one-hot: cmd is this entry's RD/WR
  output logic                                  w_starve
);

  typedef logic [1:0][DEPTH-1:0] set_t;

  set_t                 live, hit, conf, miss, hazard, waited, guarded, other_hit;
  set_t                 col_rdy, row_rdy, prep_rdy, xcol_rdy, ccand, rcand, old_sel, col_sel, row_sel;
  logic [1:0]           elig;
  logic [NUM_BANKS-1:0] hit_bank, wanted, live_wanted, starve_bank, tpre_rdy;
  logic                 starving, col_first, use_col, col_wr, row_act, keep_row;
  logic [BANK_BITS-1:0] col_bank, row_bank;
  logic [ROW_BITS-1:0]  col_row, row_row;
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


  always_comb begin
    elig[0] = !WDRAIN || !wmode;
    elig[1] = !WDRAIN ||  wmode;
    hit_bank      = '0;
    wanted        = '0;
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
        if (q_valid[q][i])         wanted[q_bank[q][i]]        = 1'b1;
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

    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        col_rdy[q][i] = live[q][i] && hit[q][i] && !hazard[q][i] && !ref_hold &&
                        bank_col_ok[q_bank[q][i]] && !starve_bank[q_bank[q][i]] &&
                        ((q == 1) ? chan_wr_ok : (chan_rd_ok && rd_slot_ok));
        row_rdy[q][i] = live[q][i] && !ref_hold && (
                          (miss[q][i] && bank_act_ok[q_bank[q][i]] && chan_act_ok) ||
                          (conf[q][i] && bank_pre_ok[q_bank[q][i]] && chan_any_ok &&
                           (!guarded[q][i] || starve_bank[q_bank[q][i]])));
        // The waiting queue may use a slot the eligible one leaves empty
        xcol_rdy[q][i] = WDRAIN && q_valid[q][i] && !elig[q] && hit[q][i] && !hazard[q][i] &&
                         !ref_hold && bank_col_ok[q_bank[q][i]] && !starve_bank[q_bank[q][i]] &&
                         ((q == 1) ? chan_wr_ok : (chan_rd_ok && rd_slot_ok));
        prep_rdy[q][i] = WDRAIN && q_valid[q][i] && !elig[q] && !ref_hold &&
                         !live_wanted[q_bank[q][i]] && (
                           (miss[q][i] && bank_act_ok[q_bank[q][i]] && chan_act_ok) ||
                           (conf[q][i] && bank_pre_ok[q_bank[q][i]] && chan_any_ok &&
                            !hit_bank[q_bank[q][i]]));
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
    col_row  = '0;
    col_col  = '0;
    row_bank = '0;
    row_row  = '0;
    for (int q = 0; q < 2; q++) begin
      for (int i = 0; i < DEPTH; i++) begin
        col_bank = col_bank | ({BANK_BITS{col_sel[q][i]}} & q_bank[q][i]);
        col_row  = col_row  | ({ROW_BITS{col_sel[q][i]}}  & q_row[q][i]);
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
                      chan_any_ok && !ref_hold;
        if (tpre_rdy[b]) tpre_bank = BANK_BITS'(b);
      end
    end
  end

  always_comb begin
    cmd       = CMD_NOP;
    cmd_bank  = '0;
    cmd_row   = '0;
    cmd_col   = '0;
    cmd_ap    = 1'b0;
    serve     = '0;
    if (ref_hold) begin
      if (|bank_open) begin
        if (chan_any_ok && ((bank_pre_ok | ~bank_open) == '1)) cmd = CMD_PREA;
      end else if (chan_any_ok && (bank_act_ok == '1)) begin
        cmd = CMD_REF;
      end
    end else if (use_col) begin
      cmd      = col_wr ? CMD_WR : CMD_RD;
      cmd_bank = col_bank;
      cmd_row  = col_row;
      cmd_col  = col_col;
      cmd_ap   = (PAGE_POLICY == PAGE_CLOSE) && !keep_row;
      serve    = col_sel;
    end else if (|rcand) begin
      cmd      = row_act ? CMD_ACT : CMD_PRE;
      cmd_bank = row_bank;
      cmd_row  = row_row;
    end else if (|tpre_rdy) begin
      cmd      = CMD_PRE;
      cmd_bank = tpre_bank;
    end
  end

endmodule
