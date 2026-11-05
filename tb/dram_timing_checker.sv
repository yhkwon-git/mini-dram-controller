// DRAM protocol and timing checker. tb/mc_bind.sv binds one instance into
// dram_model, so it sees exactly the pins the model sees.
//
// It rebuilds open rows and command timestamps from those pins alone and never
// reads mem_ctrl, so a scheduler bug cannot hide behind the scheduler's own
// bookkeeping.
//
// Timing convention: t counts clk edges after reset, and an event belongs to
// the edge that samples it. A gap is t(second) - t(first) and must be at least
// the dram_pkg value. Read data must arrive exactly RL edges after its RD and
// write data exactly WL edges after its WR (docs/spec.md, section 2).
`timescale 1ns/1ps

/* verilator lint_off BLKSEQ */
module dram_timing_checker
  import dram_pkg::*;
#(
  // 1 = count as waived (a known gap that does not fail the run), 0 = violation.
  parameter bit WAIVE_REF_OPEN = 1'b0,  // REF while a row is open
  parameter bit WAIVE_REF_DEBT = 1'b0,  // too many REFs owed
  parameter int MAX_REF_DEBT   = REF_POSTPONE_MAX,
  parameter int MAX_REPORTS    = 20     // violation lines printed before going quiet
) (
  input logic                 clk,
  input logic                 rst_n,
  input dram_cmd_e            cmd,
  input logic [BANK_BITS-1:0] bank,
  input logic [ROW_BITS-1:0]  row,
  input logic                 data_valid,
  input logic                 wdata_en
);

  typedef enum int {
    // timing gaps (minimum), then the two exact data latencies
    K_TRCD, K_TRP, K_TRAS, K_TRC, K_TRTP, K_TWR,
    K_TRRD, K_TFAW, K_TCCD, K_TWTR, K_TRTW, K_TRFC,
    K_RL, K_WL,
    // protocol
    K_ACT_OPEN, K_COL_CLOSED, K_COL_ROW,
    K_DATA_SPUR, K_DATA_LOST, K_WDATA_SPUR, K_WDATA_LOST,
    K_REF_OPEN, K_REF_DEBT,
    K_N
  } rule_e;

  localparam int     NB       = NUM_BANKS;
  localparam int     N_TIMING = 14;  // K_TRCD .. K_WL measure gaps
  localparam longint NONE     = -1;

  string       label   [K_N];
  int          spec    [K_N];
  bit          exact   [K_N];
  longint      n_chk   [K_N];
  longint      gap_min [K_N];
  int unsigned n_bad   [K_N];

  int unsigned violations;  // fail the test
  int unsigned waived;      // known gaps: counted and reported, do not fail
  int unsigned reports;
  bit          asserts_on;

  longint              t;
  longint              t_act  [NB];
  longint              t_pre  [NB];
  longint              t_rd   [NB];
  longint              t_wr   [NB];
  bit                  open_b [NB];
  logic [ROW_BITS-1:0] row_b  [NB];
  longint              t_col, t_rd_any, t_wr_any;
  longint              act_hist [4];   // last four ACTs, oldest first once full
  int                  n_act_hist;
  longint              t_ref;
  bit                  after_ref;
  longint              rd_t [$];
  longint              wr_t [$];
  longint              n_ref, ref_gap_sum, ref_gap_max, debt_max;
  bit                  debt_flagged;
  longint              n_cmd [8];

  function automatic bit is_waived(int k);
    return (k == K_REF_OPEN && WAIVE_REF_OPEN) || (k == K_REF_DEBT && WAIVE_REF_DEBT);
  endfunction

  function automatic void clear();
    for (int k = 0; k < K_N; k++) begin
      n_chk[k]   = 0;
      gap_min[k] = 64'h7FFF_FFFF;
      n_bad[k]   = 0;
    end
    for (int b = 0; b < NB; b++) begin
      t_act[b]  = NONE;
      t_pre[b]  = NONE;
      t_rd[b]   = NONE;
      t_wr[b]   = NONE;
      open_b[b] = 1'b0;
      row_b[b]  = '0;
    end
    for (int i = 0; i < 4; i++) act_hist[i] = NONE;
    for (int c = 0; c < 8; c++) n_cmd[c] = 0;
    n_act_hist   = 0;
    t_col        = NONE;
    t_rd_any     = NONE;
    t_wr_any     = NONE;
    violations   = 0;
    waived       = 0;
    reports      = 0;
    t            = 0;
    t_ref        = NONE;
    after_ref    = 1'b0;
    n_ref        = 0;
    ref_gap_sum  = 0;
    ref_gap_max  = 0;
    debt_max     = 0;
    debt_flagged = 1'b0;
    rd_t.delete();
    wr_t.delete();
  endfunction

  initial begin
    label[K_TRCD]       = "tRCD  ACT -> RD/WR";
    label[K_TRP]        = "tRP   PRE/PREA -> ACT/REF";
    label[K_TRAS]       = "tRAS  ACT -> PRE/PREA";
    label[K_TRC]        = "tRC   ACT -> ACT, same bank";
    label[K_TRTP]       = "tRTP  RD -> PRE/PREA";
    label[K_TWR]        = "tWR   WR -> PRE (WL+1+tWR)";
    label[K_TRRD]       = "tRRD  ACT -> ACT, other bank";
    label[K_TFAW]       = "tFAW  4 ACTs per window";
    label[K_TCCD]       = "tCCD  RD/WR -> RD/WR";
    label[K_TWTR]       = "tWTR  WR -> RD";
    label[K_TRTW]       = "tRTW  RD -> WR";
    label[K_TRFC]       = "tRFC  REF -> next command";
    label[K_RL]         = "RL    RD -> read data";
    label[K_WL]         = "WL    WR -> write data";
    label[K_ACT_OPEN]   = "ACT to an open bank";
    label[K_COL_CLOSED] = "RD/WR to a closed bank";
    label[K_COL_ROW]    = "RD/WR to a row not open";
    label[K_DATA_SPUR]  = "read data with no RD";
    label[K_DATA_LOST]  = "RD whose data never came";
    label[K_WDATA_SPUR] = "write data with no WR";
    label[K_WDATA_LOST] = "WR whose data never came";
    label[K_REF_OPEN]   = "REF while a row is open";
    label[K_REF_DEBT]   = $sformatf("REFs owed > %0d", MAX_REF_DEBT);
    spec[K_TRCD] = tRCD;
    spec[K_TRP]  = tRP;
    spec[K_TRAS] = tRAS;
    spec[K_TRC]  = tRC;
    spec[K_TRTP] = tRTP;
    spec[K_TWR]  = WL + 1 + tWR;
    spec[K_TRRD] = tRRD;
    spec[K_TFAW] = tFAW;
    spec[K_TCCD] = tCCD;
    spec[K_TWTR] = tWTR;
    spec[K_TRTW] = tRTW;
    spec[K_TRFC] = tRFC;
    spec[K_RL]   = RL;
    spec[K_WL]   = WL;
    for (int k = 0; k < K_N; k++) exact[k] = (k == K_RL || k == K_WL);
    for (int k = N_TIMING; k < K_N; k++) spec[k] = 0;
    clear();
    // Runs its action only when the build enables assertions (--assert).
    asserts_on = 1'b0;
    a_probe: assert (1'b0) else asserts_on = 1'b1;
  end

  function automatic void flag(rule_e k, string what);
    n_bad[k]++;
    if (is_waived(k)) begin
      waived++;
    end else begin
      violations++;
      if (reports < MAX_REPORTS) begin
        reports++;
        $display("[TCHK] VIOLATION %s at edge %0d (%0t): %s", label[k], t, $time, what);
      end
    end
  endfunction

  // Gap from an earlier event to this edge; NONE means there was no event yet.
  function automatic void gap(rule_e k, longint from, int b);
    longint d;
    if (from == NONE) return;
    d = t - from;
    n_chk[k]++;
    if (d < gap_min[k]) gap_min[k] = d;
    if (exact[k]) begin
      a_exact: assert (d == longint'(spec[k]))
        else flag(k, $sformatf("bank %0d, %0d edges, expected %0d", b, d, spec[k]));
    end else begin
      a_gap: assert (d >= longint'(spec[k]))
        else flag(k, $sformatf("bank %0d, gap %0d < %0d", b, d, spec[k]));
    end
  endfunction

  // Read and write data against the RD/WR they belong to
  function automatic void check_data();
    if (data_valid) begin
      if (rd_t.size() == 0) flag(K_DATA_SPUR, "no RD outstanding");
      else                  gap(K_RL, rd_t.pop_front(), -1);
    end
    if (rd_t.size() != 0 && (t - rd_t[0]) > longint'(RL)) begin
      flag(K_DATA_LOST, $sformatf("RD at edge %0d", rd_t[0]));
      void'(rd_t.pop_front());
    end
    if (wdata_en) begin
      if (wr_t.size() == 0) flag(K_WDATA_SPUR, "no WR outstanding");
      else                  gap(K_WL, wr_t.pop_front(), -1);
    end
    if (wr_t.size() != 0 && (t - wr_t[0]) > longint'(WL)) begin
      flag(K_WDATA_LOST, $sformatf("WR at edge %0d", wr_t[0]));
      void'(wr_t.pop_front());
    end
  endfunction

  // Close bank b with a PRE or PREA: tRAS, tRTP and write recovery apply.
  function automatic void close_bank(int b);
    if (open_b[b]) begin
      gap(K_TRAS, t_act[b], b);
      if (t_rd[b] > t_act[b]) gap(K_TRTP, t_rd[b], b);
      if (t_wr[b] > t_act[b]) gap(K_TWR, t_wr[b], b);
      open_b[b] = 1'b0;
      t_pre[b]  = t;
    end
  endfunction

  function automatic void check_cmd();
    int     b;
    longint other;
    b = int'(bank);
    n_cmd[int'(cmd)]++;
    if (after_ref) begin
      gap(K_TRFC, t_ref, b);
      after_ref = 1'b0;
    end
    case (cmd)
      CMD_ACT: begin
        if (open_b[b]) flag(K_ACT_OPEN, $sformatf("bank %0d, row %0h still open", b, row_b[b]));
        // PRE -> ACT, unless a REF sits between them (then tRP was checked at the REF)
        if (t_pre[b] > t_act[b] && t_pre[b] > t_ref) gap(K_TRP, t_pre[b], b);
        gap(K_TRC, t_act[b], b);
        other = NONE;
        for (int i = 0; i < NB; i++)
          if (i != b && t_act[i] > other) other = t_act[i];
        gap(K_TRRD, other, b);
        // tFAW: this ACT against the oldest of the previous four
        if (n_act_hist == 4) begin
          gap(K_TFAW, act_hist[0], b);
          for (int i = 0; i < 3; i++) act_hist[i] = act_hist[i+1];
          act_hist[3] = t;
        end else begin
          act_hist[n_act_hist] = t;
          n_act_hist++;
        end
        open_b[b] = 1'b1;
        row_b[b]  = row;
        t_act[b]  = t;
      end
      CMD_RD, CMD_WR: begin
        if (!open_b[b]) begin
          flag(K_COL_CLOSED, $sformatf("bank %0d", b));
        end else begin
          if (row_b[b] != row)
            flag(K_COL_ROW, $sformatf("bank %0d: open row %0h, command row %0h", b, row_b[b], row));
          gap(K_TRCD, t_act[b], b);
        end
        gap(K_TCCD, t_col, b);
        if (cmd == CMD_RD) begin
          gap(K_TWTR, t_wr_any, b);
          t_rd[b]  = t;
          t_rd_any = t;
          rd_t.push_back(t);
        end else begin
          gap(K_TRTW, t_rd_any, b);
          t_wr[b]  = t;
          t_wr_any = t;
          wr_t.push_back(t);
        end
        t_col = t;
      end
      CMD_PRE:  close_bank(b);
      CMD_PREA: for (int i = 0; i < NB; i++) close_bank(i);
      CMD_REF: begin
        for (int i = 0; i < NB; i++) begin
          if (open_b[i])
            flag(K_REF_OPEN, $sformatf("bank %0d, row %0h", i, row_b[i]));
          else if (t_pre[i] > t_act[i] && t_pre[i] > t_ref)
            gap(K_TRP, t_pre[i], i);
          open_b[i] = 1'b0;
        end
        if (t_ref != NONE) begin
          ref_gap_sum += t - t_ref;
          if (t - t_ref > ref_gap_max) ref_gap_max = t - t_ref;
        end
        n_ref++;
        t_ref     = t;
        after_ref = 1'b1;
      end
      default: ;
    endcase
  endfunction

  // REFs owed: tREFI periods elapsed minus REFs issued. A JEDEC device lets the
  // controller postpone a bounded number of REFs; more than that loses data.
  function automatic void check_refresh_debt();
    longint debt;
    debt = t / longint'(tREFI) - n_ref;
    if (debt > debt_max) debt_max = debt;
    if (debt > longint'(MAX_REF_DEBT)) begin
      if (!debt_flagged) flag(K_REF_DEBT, $sformatf("%0d REFs owed", debt));
      debt_flagged = 1'b1;
    end else begin
      debt_flagged = 1'b0;
    end
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      clear();
    end else begin
      t++;
      check_data();
      if (cmd != CMD_NOP) check_cmd();
      check_refresh_debt();
    end
  end

  function automatic string pad(string s, int w);
    string r;
    r = s;
    while (r.len() < w) r = {r, " "};
    return r;
  endfunction

  function automatic string lpad(string s, int w);
    string r;
    r = s;
    while (r.len() < w) r = {" ", r};
    return r;
  endfunction

  function automatic real ref_interval_avg();
    return (n_ref > 1) ? real'(ref_gap_sum) / real'(n_ref - 1) : 0.0;
  endfunction

  function automatic void report();
    string mn;
    string note;
    string sp;
    if (!asserts_on) begin
      violations++;
      $display("[TCHK] ERROR immediate assertions are off; build with --assert");
    end
    $display("[TCHK] %s %s %s %s %s", pad("rule", 28), lpad("spec", 6), lpad("min", 5),
             lpad("checked", 8), lpad("violations", 11));
    for (int k = 0; k < N_TIMING; k++) begin
      mn = (n_chk[k] == 0) ? "-" : $sformatf("%0d", gap_min[k]);
      sp = exact[k] ? $sformatf("=%0d", spec[k]) : $sformatf("%0d", spec[k]);
      $display("[TCHK] %s %s %s %s %s", pad(label[k], 28), lpad(sp, 6), lpad(mn, 5),
               lpad($sformatf("%0d", n_chk[k]), 8), lpad($sformatf("%0d", n_bad[k]), 11));
    end
    for (int k = N_TIMING; k < K_N; k++) begin
      // A string variable, not a ?: between literals: literals are padded to equal width.
      note = "";
      if (is_waived(k) && n_bad[k] != 0) note = "  waived";
      $display("[TCHK] %s %s%s", pad(label[k], 28), lpad($sformatf("%0d", n_bad[k]), 31), note);
    end
    $display("[TCHK] commands: ACT %0d, RD %0d, WR %0d, PRE %0d, PREA %0d, REF %0d",
             n_cmd[int'(CMD_ACT)], n_cmd[int'(CMD_RD)], n_cmd[int'(CMD_WR)],
             n_cmd[int'(CMD_PRE)], n_cmd[int'(CMD_PREA)], n_cmd[int'(CMD_REF)]);
    if (n_ref > 1)
      $display("[TCHK] REF interval avg %0.1f, max %0d edges (tREFI %0d); peak REFs owed %0d",
               ref_interval_avg(), ref_gap_max, tREFI, debt_max);
    $display("[TCHK] %s: %0d violation(s), %0d waived", (violations == 0) ? "PASS" : "FAIL",
             violations, waived);
  endfunction

endmodule
/* verilator lint_on BLKSEQ */
