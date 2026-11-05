// Synchronous DRAM model: banks, open rows, a memory array, read and write
// data pipelines, tRFC.
//
//   RD on edge t  -> data_valid and rdata registered on edge t + tCL, sampled
//                    by the controller on edge t + RL (RL = tCL + 1)
//   WR on edge t  -> the controller drives wdata_en and wdata for edge t + WL
//
// A RD/WR with ap = 1 (auto-precharge) closes its bank after the access; the
// device would precharge once tRAS, tRTP and write recovery allow, and the
// checker times the next ACT from that point.
//
// It checks state, not spacing; tb/dram_timing_checker.sv checks the spacing.
// access_err pulses for: ACT to an open bank, RD/WR to a closed bank or another
// row, REF while a bank is open, any command inside tRFC, write data that does
// not match a WR. An illegal WR does not change the array.
`timescale 1ns/1ps

module dram_model
  import dram_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,

  input  dram_cmd_e            cmd,
  input  logic [BANK_BITS-1:0] bank,
  input  logic [ROW_BITS-1:0]  row,
  input  logic [COL_BITS-1:0]  col,
  input  logic                 ap,            // auto-precharge with this RD/WR
  input  logic                 wdata_en,
  input  logic [DATA_BITS-1:0] wdata,

  output logic                 busy,          // inside tRFC after a REF
  output logic                 data_valid,
  output logic [DATA_BITS-1:0] rdata,
  output logic                 page_hit,      // the last RD/WR found its row open
  output logic                 access_err,    // pulse: illegal command or data timing
  output logic [NUM_BANKS-1:0] bank_open_oh
);

  localparam int MEM_WORDS = NUM_BANKS * (1 << ROW_BITS) * (1 << COL_BITS);
  localparam int IW        = $clog2(MEM_WORDS);

  logic                 bank_open [NUM_BANKS];
  logic [ROW_BITS-1:0]  bank_row  [NUM_BANKS];
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

  logic          hit_now;
  logic [IW-1:0] idx_now;
  logic          any_open;

  assign hit_now = bank_open[bank] && (bank_row[bank] == row);
  assign idx_now = {bank, row, col};

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

      // Commands
      if (cmd != CMD_NOP && busy) begin
        access_err <= 1'b1;  // nothing may follow REF within tRFC
      end else begin
        unique case (cmd)
          CMD_ACT: begin
            if (bank_open[bank]) access_err <= 1'b1;
            bank_open[bank] <= 1'b1;
            bank_row[bank]  <= row;
          end
          CMD_PRE: bank_open[bank] <= 1'b0;
          CMD_PREA: begin
            for (int i = 0; i < NUM_BANKS; i++) bank_open[i] <= 1'b0;
          end
          CMD_RD: begin
            page_hit   <= hit_now;
            access_err <= !hit_now;
            rd_v[0]    <= 1'b1;
            rd_ok[0]   <= hit_now;
            rd_a[0]    <= idx_now;
            if (ap) bank_open[bank] <= 1'b0;
          end
          CMD_WR: begin
            page_hit   <= hit_now;
            access_err <= !hit_now;
            wr_v[0]    <= 1'b1;
            wr_ok[0]   <= hit_now;
            wr_a[0]    <= idx_now;
            if (ap) bank_open[bank] <= 1'b0;
          end
          CMD_REF: begin
            if (any_open) access_err <= 1'b1;
            for (int i = 0; i < NUM_BANKS; i++) bank_open[i] <= 1'b0;
            busy    <= 1'b1;
            rfc_cnt <= ($bits(rfc_cnt))'(tRFC - 1);
          end
          default: ;
        endcase
      end
    end
  end

endmodule
