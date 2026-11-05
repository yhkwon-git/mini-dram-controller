// Random regression testbench for mem_ctrl_top.
//
// The env in mc_tb_pkg drives and checks the host port. The checkers bound by
// tb/mc_bind.sv watch the DRAM pins and the handshake. The block below
// classifies every column command on the DRAM pins as hit, miss or conflict.
//
// Run:      make sim-rand PATTERN=mixed SEED=1 N=2000      or      make regress
// Plusargs: +PATTERN=seq|rand|stride|stride64|hotbank|rowhit|mixed  +SEED=  +N=  +RD_PCT=
//           +GAP_MAX=  +BP_PCT=  +BP_MAX=  +STRIDE=  +HOT_PCT=  +REUSE_PCT=  +CSV=
`timescale 1ns/1ps

/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
module tb_mem_ctrl_rand
  import dram_pkg::*;
  import mc_tb_pkg::*;
#(
  // mem_ctrl parameters, settable at build time (verilator -G<name>=<value>)
  parameter int P_DEPTH        = QUEUE_DEPTH,
  parameter bit P_FR_FCFS      = 1'b1,
  parameter bit P_WDRAIN       = 1'b1,
  parameter int P_WR_HI        = 6,
  parameter int P_WR_LO        = 2,
  parameter int P_PAGE_POLICY  = PAGE_OPEN,
  parameter int P_PAGE_TIMEOUT = 16,
  parameter int P_ADDR_MAP     = MAP_XOR,
  parameter int P_CMD_BUS      = 2,
  parameter int P_REF_MODE     = REF_BANK,
  parameter bit P_RFM_EARLY    = 1'b1,
  parameter int P_RD_PIPE      = 4,
  parameter int P_STARVE_LIMIT = 160,
  parameter int P_REF_URGENT   = 4
);

  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  mc_host_if hif (clk);

  logic                 access_err;
  logic                 page_hit_unused;
  logic [NUM_BANKS-1:0] bank_open_unused;

  mem_ctrl_top #(
    .DEPTH        (P_DEPTH),
    .FR_FCFS      (P_FR_FCFS),
    .WDRAIN       (P_WDRAIN),
    .WR_HI        (P_WR_HI),
    .WR_LO        (P_WR_LO),
    .PAGE_POLICY  (P_PAGE_POLICY),
    .PAGE_TIMEOUT (P_PAGE_TIMEOUT),
    .ADDR_MAP     (P_ADDR_MAP),
    .CMD_BUS      (P_CMD_BUS),
    .REF_MODE     (P_REF_MODE),
    .RFM_EARLY    (P_RFM_EARLY),
    .RD_PIPE      (P_RD_PIPE),
    .STARVE_LIMIT (P_STARVE_LIMIT),
    .REF_URGENT   (P_REF_URGENT)
  ) dut (
    .clk            (clk),
    .rst_n          (hif.rst_n),
    .req_valid      (hif.req_valid),
    .req_ready      (hif.req_ready),
    .req_write      (hif.req_write),
    .req_addr       (hif.req_addr),
    .req_wdata      (hif.req_wdata),
    .rsp_valid      (hif.rsp_valid),
    .rsp_ready      (hif.rsp_ready),
    .rsp_rdata      (hif.rsp_rdata),
    .rsp_err        (hif.rsp_err),
    .dram_page_hit  (page_hit_unused),
    .dram_access_err(access_err),
    .dram_bank_open (bank_open_unused)
  );

  mc_env env;

  // A column command with no ACT on its bank since the previous column command
  // is a row hit. An ACT after a PRE makes it a conflict, an ACT on a closed
  // bank a miss. Auto-precharge, PREA, REF and REFpb close rows without a
  // conflict, and so does a PRE to a bank no queued request needs.
  // The column bus carries no row: the open row of each bank comes from the
  // ACTs on the row bus. The column command of an edge is handled before its
  // row command, as in the model and the checker.
  // A data beat is a cycle with read data or write data on the DRAM bus.
  bit                   act_seen [NUM_BANKS];
  bit                   pre_seen [NUM_BANKS];
  logic [ROW_BITS-1:0]  open_row [NUM_BANKS];
  int                   raa      [NUM_BANKS];  // ACTs since the bank's refreshes, as RFM counts them
  int unsigned          access_errs;
  int unsigned          rds_in_flight;
  logic [BANK_BITS-1:0] rb, cb;

  always @(posedge clk) begin
    if (hif.rst_n !== 1'b1) begin
      for (int i = 0; i < NUM_BANKS; i++) begin
        act_seen[i] = 1'b0;
        pre_seen[i] = 1'b0;
        open_row[i] = '0;
        raa[i]      = 0;
      end
      access_errs   = 0;
      rds_in_flight = 0;
    end else if (env != null) begin
      rb = dut.d_rbank;
      cb = dut.d_cbank;
      if (access_err) access_errs++;
      if (dut.d_data_valid) begin
        env.note_beat();
        rds_in_flight--;
      end
      if (dut.d_wdata_en) env.note_beat();
      if (dut.d_ccmd == CMD_RD || dut.d_ccmd == CMD_WR) begin
        env.note_col(dut.d_ccmd == CMD_WR,
                     !act_seen[cb] ? COL_HIT : (pre_seen[cb] ? COL_CONFLICT : COL_MISS));
        env.note_col_cmd(dut.d_ccmd == CMD_WR, {cb, open_row[cb], dut.d_col}, dut.d_ap,
                         int'(bg_of(cb)), hif.cyc);
        if (dut.d_ccmd == CMD_RD) begin
          rds_in_flight++;
          env.note_rd_depth(rds_in_flight);
        end
        act_seen[cb] = 1'b0;
        pre_seen[cb] = 1'b0;
      end
      if (dut.d_ccmd != CMD_NOP && dut.d_rcmd != CMD_NOP) env.note_dual();
      case (dut.d_rcmd)
        CMD_PRE: begin
          if (env.bank_wanted(int'(rb))) pre_seen[rb] = 1'b1;
          else                           env.note_pre_idle();
        end
        CMD_ACT: begin
          act_seen[rb] = 1'b1;
          open_row[rb] = dut.d_row;
          raa[rb]++;
          if (raa[rb] == RAA_MMT) env.note_raa_mmt();
        end
        CMD_PREA: begin
          for (int i = 0; i < NUM_BANKS; i++) pre_seen[i] = 1'b0;
          env.note_prea();
        end
        CMD_REF: begin
          for (int i = 0; i < NUM_BANKS; i++) begin
            pre_seen[i] = 1'b0;
            raa[i]      = (raa[i] > RAA_IMT) ? raa[i] - RAA_IMT : 0;
          end
          env.note_ref();
        end
        CMD_REFPB: begin
          pre_seen[rb] = 1'b0;
          env.note_refpb(dut.d_ccmd != CMD_NOP, raa[rb] >= RAA_IMT);
          raa[rb] = (raa[rb] > RAA_IMT) ? raa[rb] - RAA_IMT : 0;
        end
        default: ;
      endcase
    end
  end

  initial begin
    int unsigned problems;
    env = new(hif);
    env.cfg.addr_map = P_ADDR_MAP;
    if (!env.cfg.from_plusargs())
      $fatal(1, "[RAND] unknown +PATTERN=%s (seq, rand, stride, stride64, hotbank, rowhit, mixed)",
             env.cfg.pattern_name);
    env.build();
    env.drv.idle();
    env.rsp.init();
    hif.rst_n = 1'b0;
    repeat (4) @(posedge clk);
    hif.rst_n = 1'b1;
    repeat (2) @(posedge clk);
    $display("[RAND] %s", env.cfg.show());

    env.run();

    dut.u_dram.u_tchk.report();
    dut.u_hchk.report();
    problems = env.report();
    problems += dut.u_dram.u_tchk.violations;
    problems += dut.u_hchk.dut_violations + dut.u_hchk.host_violations;
    if (access_errs != 0) begin
      $display("[RAND] ERROR dram_model access_err pulses: %0d", access_errs);
      problems += access_errs;
    end
    env.write_csv(problems, dut.u_dram.u_tchk.violations, dut.u_dram.u_tchk.waived,
                  dut.u_dram.u_tchk.n_ref, dut.u_dram.u_tchk.ref_interval_avg(),
                  dut.u_dram.u_tchk.ref_gap_max, dut.u_dram.u_tchk.debt_max);
    if (problems == 0) begin
      $display("[RAND] PASS");
      $finish;
    end else begin
      $fatal(1, "[RAND] FAIL: %0d problem(s)", problems);
    end
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
