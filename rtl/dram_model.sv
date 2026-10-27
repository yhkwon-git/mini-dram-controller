// Synchronous DRAM model — banks, open-row, page hit/miss, tCL / tRFC.
// Illegal RD/WR (closed bank or wrong open row) pulses access_err and skips WR.
`timescale 1ns/1ps

module dram_model
  import dram_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst_n,

  input  dram_cmd_e                    cmd,
  input  logic [$clog2(NUM_BANKS)-1:0] bank,
  input  logic [ROW_BITS-1:0]          row,
  input  logic [COL_BITS-1:0]          col,
  input  logic [DATA_BITS-1:0]         wdata,

  output logic                         busy,
  output logic                         data_valid,
  output logic [DATA_BITS-1:0]         rdata,
  output logic                         page_hit,
  output logic                         access_err,   // pulse: RD/WR while closed or row mismatch
  output logic [NUM_BANKS-1:0]         bank_open_oh  // one-hot-ish open vector (bit i = bank i open)
);

  logic                bank_open [NUM_BANKS];
  logic [ROW_BITS-1:0] bank_row  [NUM_BANKS];

  localparam int MEM_WORDS = NUM_BANKS * (1 << ROW_BITS) * (1 << COL_BITS);
  logic [DATA_BITS-1:0] mem [MEM_WORDS];

  logic [$clog2(tRFC+1)-1:0] rfc_cnt;
  logic                      rfc_active;

  logic                         rd_active;
  logic                         rd_was_hit;
  logic [$clog2(tCL+1)-1:0]     rd_cnt;
  logic [$clog2(NUM_BANKS)-1:0] rd_bank;
  logic [ROW_BITS-1:0]          rd_row;
  logic [COL_BITS-1:0]          rd_col;

  function automatic int mem_index(
    input logic [$clog2(NUM_BANKS)-1:0] b,
    input logic [ROW_BITS-1:0] r,
    input logic [COL_BITS-1:0] c
  );
    return (int'(b) * (1 << (ROW_BITS + COL_BITS)))
         + (int'(r) * (1 << COL_BITS))
         + int'(c);
  endfunction

  always_comb begin
    for (int i = 0; i < NUM_BANKS; i++)
      bank_open_oh[i] = bank_open[i];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_BANKS; i++) begin
        bank_open[i] <= 1'b0;
        bank_row[i]  <= '0;
      end
      for (int i = 0; i < MEM_WORDS; i++)
        mem[i] <= '0;
      rfc_cnt      <= '0;
      rfc_active   <= 1'b0;
      busy         <= 1'b0;
      data_valid   <= 1'b0;
      rdata        <= '0;
      page_hit     <= 1'b0;
      access_err   <= 1'b0;
      rd_active    <= 1'b0;
      rd_was_hit   <= 1'b0;
      rd_cnt       <= '0;
      rd_bank      <= '0;
      rd_row       <= '0;
      rd_col       <= '0;
    end else begin
      data_valid <= 1'b0;
      access_err <= 1'b0;

      if (rfc_active) begin
        if (rfc_cnt <= 1) begin
          rfc_active <= 1'b0;
          busy       <= 1'b0;
          rfc_cnt    <= '0;
        end else begin
          rfc_cnt <= rfc_cnt - 1'b1;
        end
      end

      if (rd_active) begin
        if (rd_cnt <= 1) begin
          if (rd_was_hit)
            rdata <= mem[mem_index(rd_bank, rd_row, rd_col)];
          else
            rdata <= '0;
          data_valid <= 1'b1;
          page_hit   <= rd_was_hit;
          rd_active  <= 1'b0;
          rd_cnt     <= '0;
        end else begin
          rd_cnt <= rd_cnt - 1'b1;
        end
      end

      if (!rfc_active) begin
        row_match     = bank_open[bank] && (bank_row[bank] == row);
        legal_access  = row_match;

        unique case (cmd)
          CMD_ACT: begin
            // Opening a new row on an already-open bank without PRE is a conflict
            if (bank_open[bank] && bank_row[bank] != row)
              access_err <= 1'b1;
            bank_open[bank] <= 1'b1;
            bank_row[bank]  <= row;
            page_hit        <= 1'b0;
          end
          CMD_PRE: begin
            bank_open[bank] <= 1'b0;
            page_hit        <= 1'b0;
          end
          CMD_RD: begin
            page_hit   <= legal_access;
            access_err <= ~legal_access;
            rd_active  <= 1'b1;
            rd_was_hit <= legal_access;
            rd_cnt     <= tCL[$bits(rd_cnt)-1:0];
            rd_bank    <= bank;
            rd_row     <= row;
            rd_col     <= col;
          end
          CMD_WR: begin
            page_hit   <= legal_access;
            access_err <= ~legal_access;
            if (legal_access)
              mem[mem_index(bank, row, col)] <= wdata;
          end
          CMD_REF: begin
            for (int i = 0; i < NUM_BANKS; i++)
              bank_open[i] <= 1'b0;
            rfc_cnt    <= tRFC[$bits(rfc_cnt)-1:0];
            rfc_active <= 1'b1;
            busy       <= 1'b1;
            page_hit   <= 1'b0;
            rd_active  <= 1'b0;
            rd_cnt     <= '0;
            rd_was_hit <= 1'b0;
          end
          default: ;
        endcase
      end
    end
  end

endmodule
