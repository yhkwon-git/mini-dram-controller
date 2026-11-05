// Request queue. An accepted request waits here until its RD/WR is issued;
// ACT and PRE on its behalf leave it in place. The scheduler reads every entry
// each cycle.
//
// Order is kept as an age matrix instead of being worked out from tags each
// cycle: q_older[j][i] = 1 when entry j was accepted before entry i. A push
// writes the new entry's row and column of the matrix, so the scheduler finds
// the oldest of any set of entries with one AND-OR level and no compare chain.
// q_dep[i][j] = 1 while entry i waits for older entry j to the same address;
// it is written at the push and cleared when j's RD/WR issues.
`timescale 1ns/1ps

module mc_queue
  import dram_pkg::*;
#(
  parameter int DEPTH = QUEUE_DEPTH
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            push,
  input  logic                            push_write,
  input  logic [ADDR_BITS-1:0]            push_addr,
  input  logic [DATA_BITS-1:0]            push_wdata,
  input  logic [TAG_BITS-1:0]             push_tag,
  output logic                            has_free,
  input  logic                            pop,      // the RD/WR of entry pop_idx was issued
  input  logic [$clog2(DEPTH)-1:0]        pop_idx,
  output logic [DEPTH-1:0]                q_valid,
  output logic [DEPTH-1:0]                q_write,
  output logic [DEPTH-1:0][BANK_BITS-1:0] q_bank,
  output logic [DEPTH-1:0][ROW_BITS-1:0]  q_row,
  output logic [DEPTH-1:0][COL_BITS-1:0]  q_col,
  output logic [DEPTH-1:0][DATA_BITS-1:0] q_wdata,
  output logic [DEPTH-1:0][TAG_BITS-1:0]  q_tag,
  output logic [DEPTH-1:0][7:0]           q_wait,   // cycles since accept, saturating
  output logic [DEPTH-1:0][DEPTH-1:0]     q_older,  // [j][i]: j accepted before i
  output logic [DEPTH-1:0][DEPTH-1:0]     q_dep     // [i][j]: i waits for j (same address)
);

  localparam int AW = $clog2(DEPTH);

  logic [AW-1:0]    free_idx;
  logic [DEPTH-1:0] same_addr;  // entries that stay queued and hold the pushed address

  always_comb begin
    has_free = 1'b0;
    free_idx = '0;
    for (int i = DEPTH - 1; i >= 0; i--) begin
      if (!q_valid[i]) begin
        has_free = 1'b1;
        free_idx = AW'(i);
      end
    end
    for (int j = 0; j < DEPTH; j++)
      same_addr[j] = q_valid[j] && !(pop && pop_idx == AW'(j)) &&
                     ({q_bank[j], q_row[j], q_col[j]} == push_addr);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_valid <= '0;
      q_write <= '0;
      q_bank  <= '0;
      q_row   <= '0;
      q_col   <= '0;
      q_wdata <= '0;
      q_tag   <= '0;
      q_wait  <= '0;
      q_older <= '0;
      q_dep   <= '0;
    end else begin
      for (int i = 0; i < DEPTH; i++)
        if (q_valid[i] && q_wait[i] != 8'hFF) q_wait[i] <= q_wait[i] + 1'b1;
      if (pop) begin
        q_valid[pop_idx] <= 1'b0;
        for (int i = 0; i < DEPTH; i++) q_dep[i][pop_idx] <= 1'b0;
      end
      if (push) begin
        q_valid[free_idx] <= 1'b1;
        q_write[free_idx] <= push_write;
        q_bank[free_idx]  <= addr_bank(push_addr);
        q_row[free_idx]   <= addr_row(push_addr);
        q_col[free_idx]   <= addr_col(push_addr);
        q_wdata[free_idx] <= push_wdata;
        q_tag[free_idx]   <= push_tag;
        q_wait[free_idx]  <= '0;
        for (int j = 0; j < DEPTH; j++) begin
          q_older[j][free_idx] <= q_valid[j];  // everything already queued is older
          q_older[free_idx][j] <= 1'b0;
          q_dep[free_idx][j]   <= same_addr[j];
          if (j != int'(free_idx)) q_dep[j][free_idx] <= 1'b0;
        end
      end
    end
  end

endmodule
