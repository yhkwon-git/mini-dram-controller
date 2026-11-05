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
//
// Two command buses: on each edge the column command is checked first, then
// the row command, so a row command sees the column command of the same edge
// as already issued. A PRE with a RD to the same bank on one edge is then a
// tRTP violation, an ACT with a RD a "RD/WR to a closed bank".
//
// RowHammer: the checker keeps its own RAA count per bank (+1 per ACT,
// -RAA_IMT per refresh of the bank) and flags an ACT to a bank at RAA_MMT.
`timescale 1ns/1ps

/* verilator lint_off BLKSEQ */
module dram_timing_checker
  import dram_pkg::*;
#(
  // 1 = count as waived (a known gap that does not fail the run), 0 = violation.
  parameter bit WAIVE_REF_OPEN = 1'b0,  // REF while a row is open
  parameter bit WAIVE_REF_DEBT = 1'b0,  // too many refreshes owed
  parameter int MAX_REF_DEBT   = REF_POSTPONE_MAX,
  parameter int MAX_REPORTS    = 20     // violation lines printed before going quiet
) (
  input logic                 clk,
  input logic                 rst_n,
  input dram_cmd_e            rcmd,
  input logic [BANK_BITS-1:0] rbank,
  input logic [ROW_BITS-1:0]  row,
  input dram_cmd_e            ccmd,
  input logic [BANK_BITS-1:0] cbank,
  input logic                 ap,
  input logic                 data_valid,
  input logic                 wdata_en
);

  typedef enum int {
    // timing gaps (minimum), then the two exact data latencies
    K_TRCD, K_TRP, K_TRAS, K_TRC, K_TRTP, K_TWR,
    K_TRRD_S, K_TRRD_L, K_TFAW, K_TCCD_S, K_TCCD_L, K_TWTR_S, K_TWTR_L, K_TRTW,
    K_TRFC, K_TRFCPB,
    K_RL, K_WL,
    // protocol
    K_ACT_OPEN, K_COL_CLOSED,
    K_DATA_SPUR, K_DATA_LOST, K_WDATA_SPUR, K_WDATA_LOST,
    K_REF_OPEN, K_REFPB_OPEN, K_REF_DEBT, K_RAA,
    K_N
  } rule_e;

  localparam int     NB       = NUM_BANKS;
  localparam int     N_TIMING = 18;  // K_TRCD .. K_WL measure gaps
  localparam longint NONE     = -1;
  localparam longint WR_REC   = WL + 1 + tWR;  // WR -> PRE

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
  longint              t_act   [NB];
  longint              t_pre   [NB];  // PRE, PREA, or the implicit precharge of an auto-precharge
  longint              t_rd    [NB];
  longint              t_wr    [NB];
  longint              t_refpb [NB];
  longint              t_rf    [NB];  // last refresh of the bank (REF or REFPB)
  longint              n_rf    [NB];  // refreshes the bank has had
  bit                  open_b  [NB];
  logic [ROW_BITS-1:0] row_b   [NB];
  longint              t_col_bg [NUM_BG];
  longint              t_wr_bg  [NUM_BG];
  longint              t_col, t_rd_any, t_wr_any;
  longint              act_hist [4];   // last four ACTs, oldest first once full
  int                  n_act_hist;
  longint              t_ref;
  bit                  after_ref;
  longint              rd_t [$];
  longint              wr_t [$];
  longint              n_ref, rf_gaps, rf_gap_sum, ref_gap_max, debt_max;
  bit                  debt_flagged;
  longint              n_cmd [8];
  longint              n_ap, n_dual;
  int                  raa     [NB];  // ACT count for refresh management
  int                  raa_max;

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
      t_act[b]   = NONE;
      t_pre[b]   = NONE;
      t_rd[b]    = NONE;
      t_wr[b]    = NONE;
      t_refpb[b] = NONE;
      t_rf[b]    = NONE;
      n_rf[b]    = 0;
      raa[b]     = 0;
      open_b[b]  = 1'b0;
      row_b[b]   = '0;
    end
    for (int g = 0; g < NUM_BG; g++) begin
      t_col_bg[g] = NONE;
      t_wr_bg[g]  = NONE;
    end
    for (int i = 0; i < 4; i++) act_hist[i] = NONE;
    for (int c = 0; c < 8; c++) n_cmd[c] = 0;
    n_ap         = 0;
    n_dual       = 0;
    raa_max      = 0;
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
    rf_gaps      = 0;
    rf_gap_sum   = 0;
    ref_gap_max  = 0;
    debt_max     = 0;
    debt_flagged = 1'b0;
    rd_t.delete();
    wr_t.delete();
  endfunction

  initial begin
    label[K_TRCD]       = "tRCD   ACT -> RD/WR";
    label[K_TRP]        = "tRP    PRE/PREA/AP -> ACT/REF";
    label[K_TRAS]       = "tRAS   ACT -> PRE/PREA";
    label[K_TRC]        = "tRC    ACT -> ACT, same bank";
    label[K_TRTP]       = "tRTP   RD -> PRE/PREA";
    label[K_TWR]        = "tWR    WR -> PRE (WL+1+tWR)";
    label[K_TRRD_S]     = "tRRD_S ACT/REFpb -> ACT/REFpb";
    label[K_TRRD_L]     = "tRRD_L ACT -> ACT, same group";
    label[K_TFAW]       = "tFAW   4 ACTs per window";
    label[K_TCCD_S]     = "tCCD_S RD/WR -> RD/WR";
    label[K_TCCD_L]     = "tCCD_L RD/WR, same group";
    label[K_TWTR_S]     = "tWTR_S WR -> RD";
    label[K_TWTR_L]     = "tWTR_L WR -> RD, same group";
    label[K_TRTW]       = "tRTW   RD -> WR";
    label[K_TRFC]       = "tRFC   REF -> next command";
    label[K_TRFCPB]     = "tRFCpb REFpb -> ACT/REFpb, bank";
    label[K_RL]         = "RL     RD -> read data";
    label[K_WL]         = "WL     WR -> write data";
    label[K_ACT_OPEN]   = "ACT to an open bank";
    label[K_COL_CLOSED] = "RD/WR to a closed bank";
    label[K_DATA_SPUR]  = "read data with no RD";
    label[K_DATA_LOST]  = "RD whose data never came";
    label[K_WDATA_SPUR] = "write data with no WR";
    label[K_WDATA_LOST] = "WR whose data never came";
    label[K_REF_OPEN]   = "REF while a row is open";
    label[K_REFPB_OPEN] = "REFpb to an open bank";
    label[K_REF_DEBT]   = $sformatf("refreshes owed > %0d", MAX_REF_DEBT);
    label[K_RAA]        = $sformatf("ACT at RAA >= %0d (no RFM)", RAA_MMT);
    spec[K_TRCD]   = tRCD;
    spec[K_TRP]    = tRP;
    spec[K_TRAS]   = tRAS;
    spec[K_TRC]    = tRC;
    spec[K_TRTP]   = tRTP;
    spec[K_TWR]    = WL + 1 + tWR;
    spec[K_TRRD_S] = tRRD_S;
    spec[K_TRRD_L] = tRRD_L;
    spec[K_TFAW]   = tFAW;
    spec[K_TCCD_S] = tCCD_S;
    spec[K_TCCD_L] = tCCD_L;
    spec[K_TWTR_S] = tWTR_S;
    spec[K_TWTR_L] = tWTR_L;
    spec[K_TRTW]   = tRTW;
    spec[K_TRFC]   = tRFC;
    spec[K_TRFCPB] = tRFCpb;
    spec[K_RL]     = RL;
    spec[K_WL]     = WL;
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

  function automatic longint later(longint a, longint b);
    return (a > b) ? a : b;
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

  // A refresh of bank b (REF or REFPB): per-bank interval and debt
  function automatic void refreshed(int b);
    if (t_rf[b] != NONE) begin
      rf_gaps++;
      rf_gap_sum += t - t_rf[b];
      if (t - t_rf[b] > ref_gap_max) ref_gap_max = t - t_rf[b];
    end
    t_rf[b] = t;
    n_rf[b]++;
    raa[b] = (raa[b] > RAA_IMT) ? raa[b] - RAA_IMT : 0;
  endfunction

  // tRP to an ACT or a refresh: from the last PRE of the bank, unless a
  // refresh of the bank came after it (then tRP was checked at that refresh)
  function automatic void check_trp(int b);
    if (t_pre[b] > t_act[b] && t_pre[b] > t_rf[b]) gap(K_TRP, t_pre[b], b);
  endfunction

  function automatic void check_col();
    int b, g;
    b = int'(cbank);
    g = int'(bg_of(cbank));
    n_cmd[int'(ccmd)]++;
    if (!open_b[b]) begin
      flag(K_COL_CLOSED, $sformatf("bank %0d", b));
    end else begin
      gap(K_TRCD, t_act[b], b);
    end
    // Auto-precharge: the device closes the bank on the first edge a PRE
    // would meet tRAS and tRTP (RD) or write recovery (WR). That edge may lie
    // in the future; the next ACT or refresh must still be tRP after it.
    if (ap && open_b[b]) begin
      n_ap++;
      open_b[b] = 1'b0;
      t_pre[b]  = t_act[b] + longint'(tRAS);
      if (ccmd == CMD_RD && t + longint'(tRTP) > t_pre[b])         t_pre[b] = t + longint'(tRTP);
      if (ccmd == CMD_WR && t + WR_REC > t_pre[b])                 t_pre[b] = t + WR_REC;
    end
    gap(K_TCCD_L, t_col_bg[g], b);
    gap(K_TCCD_S, t_col, b);
    if (ccmd == CMD_RD) begin
      gap(K_TWTR_L, t_wr_bg[g], b);
      gap(K_TWTR_S, t_wr_any, b);
      t_rd[b]  = t;
      t_rd_any = t;
      rd_t.push_back(t);
    end else begin
      gap(K_TRTW, t_rd_any, b);
      t_wr[b]    = t;
      t_wr_any   = t;
      t_wr_bg[g] = t;
      wr_t.push_back(t);
    end
    t_col       = t;
    t_col_bg[g] = t;
  endfunction

  function automatic void check_row();
    int     b, g;
    longint same_bg, any_bank;
    b = int'(rbank);
    g = int'(bg_of(rbank));
    n_cmd[int'(rcmd)]++;
    // tRRD: the latest ACT in this group (L), the latest ACT or REFpb anywhere (S)
    same_bg  = NONE;
    any_bank = NONE;
    for (int i = 0; i < NB; i++) begin
      if (i != b) begin
        if (int'(bg_of(BANK_BITS'(i))) == g) same_bg = later(same_bg, t_act[i]);
        any_bank = later(any_bank, later(t_act[i], t_refpb[i]));
      end
    end
    case (rcmd)
      CMD_ACT: begin
        if (open_b[b]) flag(K_ACT_OPEN, $sformatf("bank %0d, row %0h still open", b, row_b[b]));
        if (raa[b] >= RAA_MMT) flag(K_RAA, $sformatf("bank %0d, RAA %0d", b, raa[b]));
        raa[b]++;
        if (raa[b] > raa_max) raa_max = raa[b];
        if (t_refpb[b] > t_act[b]) gap(K_TRFCPB, t_refpb[b], b);
        check_trp(b);
        gap(K_TRC, t_act[b], b);
        gap(K_TRRD_L, same_bg, b);
        gap(K_TRRD_S, any_bank, b);
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
      CMD_PRE:  close_bank(b);
      CMD_PREA: for (int i = 0; i < NB; i++) close_bank(i);
      CMD_REF: begin
        for (int i = 0; i < NB; i++) begin
          if (open_b[i]) flag(K_REF_OPEN, $sformatf("bank %0d, row %0h", i, row_b[i]));
          else           check_trp(i);
          open_b[i] = 1'b0;
          refreshed(i);
        end
        n_ref++;
        t_ref     = t;
        after_ref = 1'b1;
      end
      CMD_REFPB: begin
        if (open_b[b]) flag(K_REFPB_OPEN, $sformatf("bank %0d, row %0h", b, row_b[b]));
        else           check_trp(b);
        if (t_refpb[b] > t_act[b]) gap(K_TRFCPB, t_refpb[b], b);
        gap(K_TRRD_S, any_bank, b);
        open_b[b]  = 1'b0;
        t_refpb[b] = t;
        refreshed(b);
        n_ref++;
      end
      default: ;
    endcase
  endfunction

  // Refreshes owed per bank: tREFI periods elapsed minus refreshes of that
  // bank. A JEDEC device lets the controller postpone a bounded number;
  // more than that loses data.
  function automatic void check_refresh_debt();
    longint debt, worst;
    worst = 0;
    for (int b = 0; b < NB; b++) begin
      debt = t / longint'(tREFI) - n_rf[b];
      if (debt > worst) worst = debt;
    end
    if (worst > debt_max) debt_max = worst;
    if (worst > longint'(MAX_REF_DEBT)) begin
      if (!debt_flagged) flag(K_REF_DEBT, $sformatf("%0d refreshes owed", worst));
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
      if (after_ref && (ccmd != CMD_NOP || rcmd != CMD_NOP)) begin
        gap(K_TRFC, t_ref, -1);
        after_ref = 1'b0;
      end
      if (ccmd != CMD_NOP && rcmd != CMD_NOP) n_dual++;
      if (ccmd != CMD_NOP) check_col();
      if (rcmd != CMD_NOP) check_row();
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

  // Average gap between two refreshes of the same bank (tREFI in both modes)
  function automatic real ref_interval_avg();
    return (rf_gaps > 0) ? real'(rf_gap_sum) / real'(rf_gaps) : 0.0;
  endfunction

  function automatic void report();
    string mn;
    string note;
    string sp;
    if (!asserts_on) begin
      violations++;
      $display("[TCHK] ERROR immediate assertions are off; build with --assert");
    end
    $display("[TCHK] %s %s %s %s %s", pad("rule", 31), lpad("spec", 6), lpad("min", 5),
             lpad("checked", 8), lpad("violations", 11));
    for (int k = 0; k < N_TIMING; k++) begin
      mn = (n_chk[k] == 0) ? "-" : $sformatf("%0d", gap_min[k]);
      sp = exact[k] ? $sformatf("=%0d", spec[k]) : $sformatf("%0d", spec[k]);
      $display("[TCHK] %s %s %s %s %s", pad(label[k], 31), lpad(sp, 6), lpad(mn, 5),
               lpad($sformatf("%0d", n_chk[k]), 8), lpad($sformatf("%0d", n_bad[k]), 11));
    end
    for (int k = N_TIMING; k < K_N; k++) begin
      // A string variable, not a ?: between literals: literals are padded to equal width.
      note = "";
      if (is_waived(k) && n_bad[k] != 0) note = "  waived";
      $display("[TCHK] %s %s%s", pad(label[k], 31), lpad($sformatf("%0d", n_bad[k]), 31), note);
    end
    $display("[TCHK] row bus: ACT %0d, PRE %0d, PREA %0d, REF %0d, REFpb %0d; column bus: RD %0d, WR %0d (%0d with auto-precharge); both on one edge %0d",
             n_cmd[int'(CMD_ACT)], n_cmd[int'(CMD_PRE)], n_cmd[int'(CMD_PREA)], n_cmd[int'(CMD_REF)],
             n_cmd[int'(CMD_REFPB)], n_cmd[int'(CMD_RD)], n_cmd[int'(CMD_WR)], n_ap, n_dual);
    if (rf_gaps > 0)
      $display("[TCHK] refresh interval per bank avg %0.1f, max %0d edges (tREFI %0d); peak refreshes owed %0d",
               ref_interval_avg(), ref_gap_max, tREFI, debt_max);
    $display("[TCHK] peak RAA %0d (RFM due at %0d, limit %0d)", raa_max, RAA_IMT, RAA_MMT);
    $display("[TCHK] %s: %0d violation(s), %0d waived", (violations == 0) ? "PASS" : "FAIL",
             violations, waived);
  endfunction

endmodule
/* verilator lint_on BLKSEQ */
