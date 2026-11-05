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
//   address has issued its own, so a read always sees earlier writes.
// - Starvation: once the oldest request has waited STARVE_LIMIT cycles,
//   selection becomes oldest-first and, if it needs a PRE, its bank stops
//   serving younger hits.
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
  input  logic [DEPTH-1:0][TAG_BITS-1:0]      q_tag,
  input  logic [DEPTH-1:0][7:0]               q_wait,
  input  logic [TAG_BITS-1:0]                 tag_retire,
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

  logic [TAG_BITS-1:0]  age [DEPTH];  // 0 = the oldest request still in flight
  logic [DEPTH-1:0]     hit, miss, conf, hazard, guarded, col_rdy, row_rdy;
  logic                 any_valid, starving;
  logic [AW-1:0]        oldest;
  logic [NUM_BANKS-1:0] starve_bank;
  logic                 col_found, row_found, use_col;
  logic [AW-1:0]        col_pick, row_pick;

  // Age and the oldest valid request
  always_comb begin
    for (int i = 0; i < DEPTH; i++) age[i] = q_tag[i] - tag_retire;
    any_valid = 1'b0;
    oldest    = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (q_valid[i] && (!any_valid || age[i] < age[oldest])) begin
        any_valid = 1'b1;
        oldest    = AW'(i);
      end
    end
  end

  // Next command of each request and whether it is ready
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      hit[i]  = q_valid[i] &&  bank_open[q_bank[i]] && (bank_row[q_bank[i]] == q_row[i]);
      conf[i] = q_valid[i] &&  bank_open[q_bank[i]] && (bank_row[q_bank[i]] != q_row[i]);
      miss[i] = q_valid[i] && !bank_open[q_bank[i]];
    end

    for (int i = 0; i < DEPTH; i++) begin
      hazard[i]  = 1'b0;  // an older request to the same address has not issued yet
      guarded[i] = 1'b0;  // a hit on this request's bank keeps the row open
      for (int j = 0; j < DEPTH; j++) begin
        if (j != i && q_valid[j] && q_bank[j] == q_bank[i]) begin
          if (q_row[j] == q_row[i] && q_col[j] == q_col[i] && age[j] < age[i])
            hazard[i] = 1'b1;
          if (hit[j] && (FR_FCFS || age[j] < age[i]))
            guarded[i] = 1'b1;
        end
      end
    end

    starving    = any_valid && (q_wait[oldest] >= 8'(STARVE_LIMIT));
    starve_bank = '0;
    if (starving && conf[oldest]) starve_bank[q_bank[oldest]] = 1'b1;

    for (int i = 0; i < DEPTH; i++) begin
      col_rdy[i] = hit[i] && !hazard[i] && !ref_hold && bank_col_ok[q_bank[i]] &&
                   !starve_bank[q_bank[i]] &&
                   (q_write[i] ? chan_wr_ok : (chan_rd_ok && rd_slot_ok));
      row_rdy[i] = !ref_hold && (
                     (miss[i] && bank_act_ok[q_bank[i]] && chan_act_ok) ||
                     (conf[i] && bank_pre_ok[q_bank[i]] && chan_any_ok &&
                      (!guarded[i] || starve_bank[q_bank[i]])));
    end
  end

  // Oldest ready RD/WR and oldest ready ACT/PRE
  always_comb begin
    col_found = 1'b0;
    col_pick  = '0;
    row_found = 1'b0;
    row_pick  = '0;
    for (int i = 0; i < DEPTH; i++) begin
      if (col_rdy[i] && (!col_found || age[i] < age[col_pick])) begin
        col_found = 1'b1;
        col_pick  = AW'(i);
      end
      if (row_rdy[i] && (!row_found || age[i] < age[row_pick])) begin
        row_found = 1'b1;
        row_pick  = AW'(i);
      end
    end
    if (FR_FCFS && !starving)
      use_col = col_found;
    else
      use_col = col_found && (!row_found || age[col_pick] < age[row_pick]);
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
    end else if (row_found) begin
      cmd      = miss[row_pick] ? CMD_ACT : CMD_PRE;
      cmd_bank = q_bank[row_pick];
      cmd_row  = q_row[row_pick];
    end
  end

endmodule
