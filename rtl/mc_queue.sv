// Request queue, one per direction: mem_ctrl keeps a read queue and a write
// queue. An accepted request waits here until its RD/WR is issued; ACT and PRE
// on its behalf leave it in place. The scheduler reads every entry each cycle.
//
// Order is kept as an age matrix instead of being worked out from tags each
// cycle: q_older[j][i] = 1 when entry j was accepted before entry i. A push
// writes the new entry's row and column of the matrix, so the scheduler finds
// the oldest of any set of entries with one AND-OR level and no compare chain.
//
// ORDERED = 1 (write queue): q_dep[i][j] = 1 while entry i waits for older
// entry j to the same address, so two writes to one address reach the DRAM in
// order. It is written at the push; once j has issued, q_valid[j] masks the
// bit, and the next push into slot j clears column j.
// ORDERED = 0 (read queue): reads to one address need no order; q_dep is 0.
//
// match flags the valid entries that hold the address being pushed (or
// offered on the host port), including one whose RD/WR issues on this edge.
// Leaving the pop out keeps the scheduler off the accept path; mem_ctrl uses
// match to forward a read or hold a write, and both stay correct when the
// matching entry is leaving. A dependency recorded on a leaving entry is
// masked by q_valid and cleared when its slot is reused.
`timescale 1ns/1ps

module mc_queue
  import dram_pkg::*;
#(
  parameter int DEPTH   = QUEUE_DEPTH,
  parameter bit ORDERED = 1'b1
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            push,
  input  logic [BANK_BITS-1:0]            push_bank,
  input  logic [ROW_BITS-1:0]             push_row,
  input  logic [COL_BITS-1:0]             push_col,
  input  logic [DATA_BITS-1:0]            push_wdata,
  input  logic [TAG_BITS-1:0]             push_tag,
  output logic                            has_free,
  output logic [$clog2(DEPTH)-1:0]        free_idx,
  output logic [DEPTH-1:0]                match,
  input  logic [DEPTH-1:0]                pop,      // one-hot: this entry's RD/WR was issued
  output logic [DEPTH-1:0]                q_valid,
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

  always_comb begin
    has_free = 1'b0;
    free_idx = '0;
    for (int i = DEPTH - 1; i >= 0; i--) begin
      if (!q_valid[i]) begin
        has_free = 1'b1;
        free_idx = i[AW-1:0];
      end
    end
    for (int j = 0; j < DEPTH; j++)
      match[j] = q_valid[j] &&
                 q_bank[j] == push_bank && q_row[j] == push_row && q_col[j] == push_col;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_valid <= '0;
      q_bank  <= '0;
      q_row   <= '0;
      q_col   <= '0;
      q_wdata <= '0;
      q_tag   <= '0;
      q_wait  <= '0;
      q_older <= '0;
    end else begin
      for (int i = 0; i < DEPTH; i++)
        if (q_valid[i] && q_wait[i] != 8'hFF) q_wait[i] <= q_wait[i] + 1'b1;
      q_valid <= q_valid & ~pop;
      if (push) begin
        q_valid[free_idx] <= 1'b1;
        q_bank[free_idx]  <= push_bank;
        q_row[free_idx]   <= push_row;
        q_col[free_idx]   <= push_col;
        q_wdata[free_idx] <= push_wdata;
        q_tag[free_idx]   <= push_tag;
        q_wait[free_idx]  <= '0;
        for (int j = 0; j < DEPTH; j++) begin
          q_older[j][free_idx] <= q_valid[j];  // everything already queued is older
          q_older[free_idx][j] <= 1'b0;
        end
      end
    end
  end

  if (ORDERED) begin : g_dep
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        q_dep <= '0;
      end else begin
        if (push)
          for (int j = 0; j < DEPTH; j++) begin
            q_dep[free_idx][j] <= match[j];
            if (j != int'(free_idx)) q_dep[j][free_idx] <= 1'b0;
          end
      end
    end
  end else begin : g_no_dep
    assign q_dep = '0;
  end

endmodule
