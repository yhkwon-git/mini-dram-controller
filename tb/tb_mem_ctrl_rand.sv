// Random regression testbench for mem_ctrl_top.
//
// The env in mc_tb_pkg drives and checks the host port. The checkers bound by
// tb/mc_bind.sv watch the DRAM pins and the handshake. The block below
// classifies every column command on the DRAM pins as hit, miss or conflict.
//
// Run:      make sim-rand PATTERN=mixed SEED=1 N=2000      or      make regress
// Plusargs: +PATTERN=seq|rand|stride|hotbank|rowhit|mixed  +SEED=  +N=  +RD_PCT=
//           +GAP_MAX=  +BP_PCT=  +BP_MAX=  +STRIDE=  +HOT_PCT=  +REUSE_PCT=  +CSV=
`timescale 1ns/1ps

/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
module tb_mem_ctrl_rand
  import dram_pkg::*;
  import mc_tb_pkg::*;
;

  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  mc_host_if hif (clk);

  logic                 access_err;
  logic                 page_hit_unused;
  logic [NUM_BANKS-1:0] bank_open_unused;

  mem_ctrl_top dut (
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
  // bank a miss. REF closes every row.
  bit          act_seen [NUM_BANKS];
  bit          pre_seen [NUM_BANKS];
  int unsigned          access_errs;
  logic [BANK_BITS-1:0] b;

  always @(posedge clk) begin
    if (hif.rst_n !== 1'b1) begin
      for (int i = 0; i < NUM_BANKS; i++) begin
        act_seen[i] = 1'b0;
        pre_seen[i] = 1'b0;
      end
      access_errs = 0;
    end else if (env != null) begin
      b = dut.d_bank;
      if (access_err) access_errs++;
      if (dut.d_data_valid) env.note_beat();
      case (dut.d_cmd)
        CMD_PRE: pre_seen[b] = 1'b1;
        CMD_ACT: act_seen[b] = 1'b1;
        CMD_RD, CMD_WR: begin
          env.note_col(dut.d_cmd == CMD_WR,
                       !act_seen[b] ? COL_HIT : (pre_seen[b] ? COL_CONFLICT : COL_MISS));
          env.note_col_cmd(dut.d_cmd == CMD_WR, {dut.d_bank, dut.d_row, dut.d_col});
          if (dut.d_cmd == CMD_WR) env.note_beat();
          act_seen[b] = 1'b0;
          pre_seen[b] = 1'b0;
        end
        CMD_REF: begin
          for (int i = 0; i < NUM_BANKS; i++) pre_seen[i] = 1'b0;
          env.note_ref();
        end
        default: ;
      endcase
    end
  end

  initial begin
    int unsigned problems;
    env = new(hif);
    if (!env.cfg.from_plusargs())
      $fatal(1, "[RAND] unknown +PATTERN=%s (seq, rand, stride, hotbank, rowhit, mixed)",
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
