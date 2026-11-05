// DRAM protocol and timing checker. tb/mc_bind.sv binds one instance into
// dram_model, so it sees exactly the command pins the model sees.
//
// It rebuilds open rows and command timestamps from those pins alone and never
// reads mem_ctrl, so a scheduler bug cannot hide behind the scheduler's own
// bookkeeping.
//
// Timing convention: t counts clk edges after reset, and a command (or
// data_valid) belongs to the edge that samples it. A gap is t(second) -
// t(first) and must be at least the dram_pkg value. Read data must arrive
// exactly tCL + 1 edges after its RD (docs/spec.md, section 2).
`timescale 1ns/1ps

/* verilator lint_off BLKSEQ */
module dram_timing_checker
  import dram_pkg::*;
#(
  // Known v1 gaps, listed in README "다음 단계".
  // 1 = count them as waived, 0 = count them as violations.
  parameter bit WAIVE_REF_OPEN = 1'b1,  // REF while a row is open (v1 issues no PREA)
  parameter bit WAIVE_REF_DEBT = 1'b1,  // refi_cnt reloads after REF, so REFs drift late
  parameter int MAX_REF_DEBT   = 8,     // REFs owed before the debt rule fires (DDR4 allows 8 postponed)
  parameter int MAX_REPORTS    = 20     // violation lines printed before going quiet
) (
  input logic                         clk,
  input logic                         rst_n,
  input dram_cmd_e                    cmd,
  input logic [$clog2(NUM_BANKS)-1:0] bank,
  input logic [ROW_BITS-1:0]          row,
  input logic                         data_valid
);

  typedef enum int {
    // timing gaps
    K_TRCD, K_TRP, K_TRAS, K_TRC, K_TWR, K_TRFC, K_TCL,
    // protocol
    K_ACT_OPEN, K_COL_CLOSED, K_COL_ROW, K_DATA_SPUR, K_DATA_LOST,
    // refresh (waivable)
    K_REF_OPEN, K_REF_DEBT,
    K_N
  } rule_e;

  localparam int     NB       = NUM_BANKS;
  localparam int     N_TIMING = 7;  // K_TRCD .. K_TCL measure gaps
  localparam longint NONE     = -1;

  string       label   [K_N];
  int          spec    [K_N];
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
  longint              t_wr   [NB];
  bit                  open_b [NB];
  logic [ROW_BITS-1:0] row_b  [NB];
  longint              t_ref;
  bit                  after_ref;
  longint              rd_t [$];
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
      t_wr[b]   = NONE;
      open_b[b] = 1'b0;
      row_b[b]  = '0;
    end
    for (int c = 0; c < 8; c++) n_cmd[c] = 0;
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
  endfunction

  initial begin
    label[K_TRCD]       = "tRCD  ACT -> RD/WR";
    label[K_TRP]        = "tRP   PRE -> ACT/REF";
    label[K_TRAS]       = "tRAS  ACT -> PRE";
    label[K_TRC]        = "tRC   ACT -> ACT";
    label[K_TWR]        = "tWR   WR -> PRE";
    label[K_TRFC]       = "tRFC  REF -> next command";
    label[K_TCL]        = "tCL   RD -> data (exact)";
    label[K_ACT_OPEN]   = "ACT to an open bank";
    label[K_COL_CLOSED] = "RD/WR to a closed bank";
    label[K_COL_ROW]    = "RD/WR to a row not open";
    label[K_DATA_SPUR]  = "data_valid with no RD";
    label[K_DATA_LOST]  = "RD whose data never came";
    label[K_REF_OPEN]   = "REF while a row is open";
    label[K_REF_DEBT]   = $sformatf("refresh debt > %0d tREFI", MAX_REF_DEBT);
    spec[K_TRCD] = tRCD;
    spec[K_TRP]  = tRP;
    spec[K_TRAS] = tRAS;
    spec[K_TRC]  = tRC;
    spec[K_TWR]  = tWR;
    spec[K_TRFC] = tRFC;
    spec[K_TCL]  = tCL + 1;
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
    a_gap: assert (d >= longint'(spec[k]))
      else flag(k, $sformatf("bank %0d, gap %0d < %0d", b, d, spec[k]));
  endfunction

  function automatic void check_data();
    longint d;
    if (data_valid) begin
      if (rd_t.size() == 0) begin
        flag(K_DATA_SPUR, "no RD outstanding");
      end else begin
        d = t - rd_t.pop_front();
        n_chk[K_TCL]++;
        if (d < gap_min[K_TCL]) gap_min[K_TCL] = d;
        a_tcl: assert (d == longint'(spec[K_TCL]))
          else flag(K_TCL, $sformatf("data %0d edges after RD, expected %0d", d, spec[K_TCL]));
      end
    end
    if (rd_t.size() != 0 && (t - rd_t[0]) > longint'(spec[K_TCL])) begin
      flag(K_DATA_LOST, $sformatf("RD at edge %0d", rd_t[0]));
      void'(rd_t.pop_front());
    end
  endfunction

  function automatic void check_cmd();
    int b;
    b = int'(bank);
    n_cmd[int'(cmd)]++;
    if (after_ref) begin
      gap(K_TRFC, t_ref, b);
      after_ref = 1'b0;
    end
    case (cmd)
      CMD_ACT: begin
        if (open_b[b]) flag(K_ACT_OPEN, $sformatf("bank %0d, row %0h still open", b, row_b[b]));
        // PRE -> ACT, unless a REF sits between them (then tRP is checked at the REF)
        if (t_pre[b] > t_act[b] && t_pre[b] > t_ref) gap(K_TRP, t_pre[b], b);
        gap(K_TRC, t_act[b], b);
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
        if (cmd == CMD_WR) t_wr[b] = t;
        else               rd_t.push_back(t);
      end
      CMD_PRE: begin
        if (open_b[b]) begin
          gap(K_TRAS, t_act[b], b);
          if (t_wr[b] > t_act[b]) gap(K_TWR, t_wr[b], b);
        end
        open_b[b] = 1'b0;
        t_pre[b]  = t;
      end
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
    if (!asserts_on) begin
      violations++;
      $display("[TCHK] ERROR immediate assertions are off; build with --assert");
    end
    $display("[TCHK] %s %s %s %s %s", pad("rule", 28), lpad("spec", 5), lpad("min", 5),
             lpad("checked", 8), lpad("violations", 11));
    for (int k = 0; k < N_TIMING; k++) begin
      mn = (n_chk[k] == 0) ? "-" : $sformatf("%0d", gap_min[k]);
      $display("[TCHK] %s %s %s %s %s", pad(label[k], 28), lpad($sformatf("%0d", spec[k]), 5),
               lpad(mn, 5), lpad($sformatf("%0d", n_chk[k]), 8), lpad($sformatf("%0d", n_bad[k]), 11));
    end
    for (int k = N_TIMING; k < K_N; k++) begin
      // A string variable, not a ?: between literals: literals are padded to equal width.
      note = "";
      if (is_waived(k) && n_bad[k] != 0) note = "  waived (known v1 gap)";
      $display("[TCHK] %s %s%s", pad(label[k], 28), lpad($sformatf("%0d", n_bad[k]), 30), note);
    end
    $display("[TCHK] commands: ACT %0d, RD %0d, WR %0d, PRE %0d, REF %0d",
             n_cmd[int'(CMD_ACT)], n_cmd[int'(CMD_RD)], n_cmd[int'(CMD_WR)],
             n_cmd[int'(CMD_PRE)], n_cmd[int'(CMD_REF)]);
    if (n_ref > 1)
      $display("[TCHK] REF interval avg %0.1f, max %0d edges (tREFI %0d); peak refresh debt %0d",
               ref_interval_avg(), ref_gap_max, tREFI, debt_max);
    $display("[TCHK] %s: %0d violation(s), %0d waived", (violations == 0) ? "PASS" : "FAIL",
             violations, waived);
  endfunction

endmodule
/* verilator lint_on BLKSEQ */
