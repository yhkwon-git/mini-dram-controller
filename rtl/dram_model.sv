// Synchronous DRAM model: banks in two bank groups, open rows, a memory array,
// read and write data pipelines, tRFC and per-bank tRFCpb.
//
// Two command buses, both sampled on every edge:
//   row bus     ACT, PRE, PREA, REF (all banks), REFPB (one bank)
//   column bus  RD, WR, with ap (auto-precharge); no row: the open row is used
//
//   RD on edge t  -> data_valid and rdata registered on edge t + tCL, sampled
//                    by the controller on edge t + RL (RL = tCL + 1)
//   WR on edge t  -> the controller drives wdata_en and wdata for edge t + WL
//
// A RD/WR with ap = 1 closes its bank after the access; the device would
// precharge once tRAS, tRTP and write recovery allow, and the checker times
// the next ACT from that point.
//
// It checks state, not spacing; tb/dram_timing_checker.sv checks the spacing.
// access_err pulses for: ACT to an open bank, RD/WR to a closed bank, REF
// while a bank is open, REFPB to an open bank, any command inside tRFC, a
// command to a bank inside its tRFCpb, write data that does not match a WR.
// An illegal WR does not change the array.
`timescale 1ns/1ps

module dram_model
  import dram_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,

  input  dram_cmd_e            rcmd,          // row bus
  input  logic [BANK_BITS-1:0] rbank,
  input  logic [ROW_BITS-1:0]  row,
  input  dram_cmd_e            ccmd,          // column bus
  input  logic [BANK_BITS-1:0] cbank,
  input  logic [COL_BITS-1:0]  col,
  input  logic                 ap,            // auto-precharge with this RD/WR
  input  logic                 wdata_en,
  input  logic [DATA_BITS-1:0] wdata,

  output logic                 busy,          // inside tRFC after an all-bank REF
  output logic                 data_valid,
  output logic [DATA_BITS-1:0] rdata,
  output logic                 page_hit,      // the last RD/WR found its bank open
  output logic                 access_err,    // pulse: illegal command or data timing
  output logic [NUM_BANKS-1:0] bank_open_oh
);

  localparam int MEM_WORDS = NUM_BANKS * (1 << ROW_BITS) * (1 << COL_BITS);
  localparam int IW        = $clog2(MEM_WORDS);

  logic                 bank_open [NUM_BANKS];
  logic [ROW_BITS-1:0]  bank_row  [NUM_BANKS];
  logic [3:0]           pb_cnt    [NUM_BANKS];  // tRFCpb left after a REFPB
  logic [DATA_BITS-1:0] mem [MEM_WORDS];

  logic [$clog2(tRFC+1)-1:0] rfc_cnt;

  // Read pipeline: stage k holds a RD issued k edges ago
  logic          rd_v  [tCL];
  logic          rd_ok [tCL];
  logic [IW-1:0] rd_a  [tCL];
  // Write pipeline: stage k holds a WR issued k edges ago
  logic          wr_v  [WL];
  logic          wr_ok [WL];
  logic [IW-1:0] wr_a  [WL];

  logic          col_open, col_busy, row_busy;
  logic [IW-1:0] idx_now;
  logic          any_open;

  assign col_open = bank_open[cbank];
  assign col_busy = pb_cnt[cbank] != '0;
  assign row_busy = pb_cnt[rbank] != '0;
  assign idx_now  = {cbank, bank_row[cbank], col};

  always_comb begin
    any_open = 1'b0;
    for (int i = 0; i < NUM_BANKS; i++) begin
      bank_open_oh[i] = bank_open[i];
      any_open        = any_open | bank_open[i];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_BANKS; i++) begin
        bank_open[i] <= 1'b0;
        bank_row[i]  <= '0;
        pb_cnt[i]    <= '0;
      end
      for (int i = 0; i < MEM_WORDS; i++) mem[i] <= '0;
      for (int k = 0; k < tCL; k++) begin
        rd_v[k]  <= 1'b0;
        rd_ok[k] <= 1'b0;
        rd_a[k]  <= '0;
      end
      for (int k = 0; k < WL; k++) begin
        wr_v[k]  <= 1'b0;
        wr_ok[k] <= 1'b0;
        wr_a[k]  <= '0;
      end
      rfc_cnt    <= '0;
      busy       <= 1'b0;
      data_valid <= 1'b0;
      rdata      <= '0;
      page_hit   <= 1'b0;
      access_err <= 1'b0;
    end else begin
      access_err <= 1'b0;

      // tRFC window
      if (busy) begin
        if (rfc_cnt <= 1) begin
          busy    <= 1'b0;
          rfc_cnt <= '0;
        end else begin
          rfc_cnt <= rfc_cnt - 1'b1;
        end
      end
      for (int i = 0; i < NUM_BANKS; i++)
        if (pb_cnt[i] != '0) pb_cnt[i] <= pb_cnt[i] - 1'b1;

      // Read data out of the last stage
      data_valid <= rd_v[tCL-1];
      rdata      <= (rd_v[tCL-1] && rd_ok[tCL-1]) ? mem[rd_a[tCL-1]] : '0;
      for (int k = tCL - 1; k > 0; k--) begin
        rd_v[k]  <= rd_v[k-1];
        rd_ok[k] <= rd_ok[k-1];
        rd_a[k]  <= rd_a[k-1];
      end
      rd_v[0] <= 1'b0;

      // Write data into the array
      if (wdata_en) begin
        if (wr_v[WL-1] && wr_ok[WL-1]) mem[wr_a[WL-1]] <= wdata;
        if (!wr_v[WL-1]) access_err <= 1'b1;
      end else if (wr_v[WL-1]) begin
        access_err <= 1'b1;  // a WR whose data never came
      end
      for (int k = WL - 1; k > 0; k--) begin
        wr_v[k]  <= wr_v[k-1];
        wr_ok[k] <= wr_ok[k-1];
        wr_a[k]  <= wr_a[k-1];
      end
      wr_v[0] <= 1'b0;

      // Column bus (sees the bank state before this edge's row command)
      if (ccmd != CMD_NOP && (busy || col_busy)) begin
        access_err <= 1'b1;  // nothing may follow REF within tRFC, or REFPB within tRFCpb
      end else if (ccmd == CMD_RD || ccmd == CMD_WR) begin
        page_hit <= col_open;
        if (!col_open) access_err <= 1'b1;
        if (ccmd == CMD_RD) begin
          rd_v[0]  <= 1'b1;
          rd_ok[0] <= col_open;
          rd_a[0]  <= idx_now;
        end else begin
          wr_v[0]  <= 1'b1;
          wr_ok[0] <= col_open;
          wr_a[0]  <= idx_now;
        end
        if (ap) bank_open[cbank] <= 1'b0;
      end else if (ccmd != CMD_NOP) begin
        access_err <= 1'b1;  // a row command on the column bus
      end

      // Row bus
      if (rcmd != CMD_NOP && (busy || (rcmd != CMD_PREA && rcmd != CMD_REF && row_busy))) begin
        access_err <= 1'b1;
      end else begin
        unique case (rcmd)
          CMD_NOP: ;
          CMD_ACT: begin
            if (bank_open[rbank]) access_err <= 1'b1;
            bank_open[rbank] <= 1'b1;
            bank_row[rbank]  <= row;
          end
          CMD_PRE: bank_open[rbank] <= 1'b0;
          CMD_PREA: begin
            for (int i = 0; i < NUM_BANKS; i++) bank_open[i] <= 1'b0;
          end
          CMD_REF: begin
            if (any_open) access_err <= 1'b1;
            for (int i = 0; i < NUM_BANKS; i++) bank_open[i] <= 1'b0;
            busy    <= 1'b1;
            rfc_cnt <= ($bits(rfc_cnt))'(tRFC - 1);
          end
          CMD_REFPB: begin
            if (bank_open[rbank]) access_err <= 1'b1;
            bank_open[rbank] <= 1'b0;
            pb_cnt[rbank]    <= 4'(tRFCpb - 1);
          end
          default: access_err <= 1'b1;  // a column command on the row bus
        endcase
      end
    end
  end

endmodule
