// Command scheduler: picks at most one DRAM command per cycle.
//
// Each queued request needs one next command:
//   RD/WR when its row is open (hit), ACT when its bank is closed (miss),
//   PRE when another row is open (conflict).
// It is ready when that command meets every bank and channel timing rule.
//
// FR_FCFS = 1: the oldest ready RD/WR first, else the oldest ready ACT/PRE.
//              A bank is not precharged while any queued request hits its row.
// FR_FCFS = 0: the oldest ready command of any kind. A bank is not
//              precharged while an older request hits its row.
//
// Two guards:
// - Same address: a RD/WR waits until every older request to the same
//   address has issued its own (q_dep), so a read always sees earlier writes.
// - Starvation: once the oldest request has waited STARVE_LIMIT cycles,
//   selection becomes oldest-first and, if it needs a PRE, its bank stops
//   serving younger hits.
//
// "Oldest" comes from the queue's age matrix: the oldest member of a set is
// the one that no other member is older than, an AND-OR over the set.
//
// Refresh (ref_hold): no ACT and no RD/WR. PREA once every open bank may
// precharge, then REF once every bank has met tRP and tRC.
`timescale 1ns/1ps

module mc_sched
  import dram_pkg::*;
#(
  parameter int DEPTH        = QUEUE_DEPTH,
  parameter bit FR_FCFS      = 1'b1,
  parameter int STARVE_LIMIT = 160
) (
  input  logic [DEPTH-1:0]                    q_valid,
  input  logic [DEPTH-1:0]                    q_write,
  input  logic [DEPTH-1:0][BANK_BITS-1:0]     q_bank,
  input  logic [DEPTH-1:0][ROW_BITS-1:0]      q_row,
  input  logic [DEPTH-1:0][COL_BITS-1:0]      q_col,
  input  logic [DEPTH-1:0][7:0]               q_wait,
  input  logic [DEPTH-1:0][DEPTH-1:0]         q_older,
  input  logic [DEPTH-1:0][DEPTH-1:0]         q_dep,
  input  logic [NUM_BANKS-1:0]                bank_open,
  input  logic [NUM_BANKS-1:0][ROW_BITS-1:0]  bank_row,
  input  logic [NUM_BANKS-1:0]                bank_act_ok,
  input  logic [NUM_BANKS-1:0]                bank_col_ok,
  input  logic [NUM_BANKS-1:0]                bank_pre_ok,
  input  logic                                chan_act_ok,
  input  logic                                chan_rd_ok,
  input  logic                                chan_wr_ok,
  input  logic                                chan_any_ok,
  input  logic                                rd_slot_ok,
  input  logic                                ref_hold,
  output dram_cmd_e                           cmd,
  output logic [BANK_BITS-1:0]                cmd_bank,
  output logic [ROW_BITS-1:0]                 cmd_row,
  output logic [COL_BITS-1:0]                 cmd_col,
  output logic                                serve,      // cmd is the RD/WR of entry serve_idx
  output logic [$clog2(DEPTH)-1:0]            serve_idx
);

  localparam int AW = $clog2(DEPTH);

  logic [DEPTH-1:0]     hit, miss, conf, hazard, guarded, waited, col_rdy, row_rdy;
  logic [DEPTH-1:0]     old_sel, col_sel, row_sel;
  logic                 starving, col_first, use_col;
  logic [NUM_BANKS-1:0] starve_bank;
  logic [AW-1:0]        col_pick, row_pick;

  // One-hot: the member of m that no other member of m is older than.
  function automatic logic [DEPTH-1:0] oldest_of(input logic [DEPTH-1:0] m);
    logic [DEPTH-1:0] r;
    for (int i = 0; i < DEPTH; i++) begin
      r[i] = m[i];
      for (int j = 0; j < DEPTH; j++)
        if (j != i && m[j] && q_older[j][i]) r[i] = 1'b0;
    end
    return r;
  endfunction

  function automatic logic [AW-1:0] index_of(input logic [DEPTH-1:0] onehot);
    logic [AW-1:0] r;
    r = '0;
    for (int i = 0; i < DEPTH; i++)
      if (onehot[i]) r = r | AW'(i);
    return r;
  endfunction

  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      hit[i]    = q_valid[i] &&  bank_open[q_bank[i]] && (bank_row[q_bank[i]] == q_row[i]);
      conf[i]   = q_valid[i] &&  bank_open[q_bank[i]] && (bank_row[q_bank[i]] != q_row[i]);
      miss[i]   = q_valid[i] && !bank_open[q_bank[i]];
      hazard[i] = |(q_dep[i] & q_valid);
      waited[i] = q_wait[i] >= 8'(STARVE_LIMIT);
    end

    // A hit on the same bank keeps the row open: any hit for FR-FCFS, an older one for FCFS
    for (int i = 0; i < DEPTH; i++) begin
      guarded[i] = 1'b0;
      for (int j = 0; j < DEPTH; j++)
        if (j != i && hit[j] && q_bank[j] == q_bank[i] && (FR_FCFS || q_older[j][i]))
          guarded[i] = 1'b1;
    end

    old_sel     = oldest_of(q_valid);
    starving    = |(old_sel & waited);
    starve_bank = '0;
    for (int i = 0; i < DEPTH; i++)
      if (starving && old_sel[i] && conf[i]) starve_bank[q_bank[i]] = 1'b1;

    for (int i = 0; i < DEPTH; i++) begin
      col_rdy[i] = hit[i] && !hazard[i] && !ref_hold && bank_col_ok[q_bank[i]] &&
                   !starve_bank[q_bank[i]] &&
                   (q_write[i] ? chan_wr_ok : (chan_rd_ok && rd_slot_ok));
      row_rdy[i] = !ref_hold && (
                     (miss[i] && bank_act_ok[q_bank[i]] && chan_act_ok) ||
                     (conf[i] && bank_pre_ok[q_bank[i]] && chan_any_ok &&
                      (!guarded[i] || starve_bank[q_bank[i]])));
    end

    col_sel   = oldest_of(col_rdy);
    row_sel   = oldest_of(row_rdy);
    col_first = 1'b0;
    for (int i = 0; i < DEPTH; i++)
      for (int j = 0; j < DEPTH; j++)
        if (col_sel[i] && row_sel[j] && q_older[i][j]) col_first = 1'b1;
    if (FR_FCFS && !starving)
      use_col = |col_rdy;
    else
      use_col = |col_rdy && (!(|row_rdy) || col_first);
    col_pick = index_of(col_sel);
    row_pick = index_of(row_sel);
  end

  always_comb begin
    cmd       = CMD_NOP;
    cmd_bank  = '0;
    cmd_row   = '0;
    cmd_col   = '0;
    serve     = 1'b0;
    serve_idx = '0;
    if (ref_hold) begin
      if (|bank_open) begin
        if (chan_any_ok && ((bank_pre_ok | ~bank_open) == '1)) cmd = CMD_PREA;
      end else if (chan_any_ok && (bank_act_ok == '1)) begin
        cmd = CMD_REF;
      end
    end else if (use_col) begin
      cmd       = q_write[col_pick] ? CMD_WR : CMD_RD;
      cmd_bank  = q_bank[col_pick];
      cmd_row   = q_row[col_pick];
      cmd_col   = q_col[col_pick];
      serve     = 1'b1;
      serve_idx = col_pick;
    end else if (|row_rdy) begin
      cmd      = miss[row_pick] ? CMD_ACT : CMD_PRE;
      cmd_bank = q_bank[row_pick];
      cmd_row  = q_row[row_pick];
    end
  end

endmodule
