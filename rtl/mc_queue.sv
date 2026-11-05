// Request queue. An accepted request waits here until its RD/WR is issued;
// ACT and PRE on its behalf leave it in place. The scheduler reads every entry
// each cycle. Age comes from the response tag, handed out in arrival order.
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
  output logic [DEPTH-1:0][7:0]           q_wait    // cycles since accept, saturating
);

  localparam int AW = $clog2(DEPTH);

  logic [AW-1:0] free_idx;

  always_comb begin
    has_free = 1'b0;
    free_idx = '0;
    for (int i = DEPTH - 1; i >= 0; i--) begin
      if (!q_valid[i]) begin
        has_free = 1'b1;
        free_idx = AW'(i);
      end
    end
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
    end else begin
      for (int i = 0; i < DEPTH; i++)
        if (q_valid[i] && q_wait[i] != 8'hFF) q_wait[i] <= q_wait[i] + 1'b1;
      if (pop) q_valid[pop_idx] <= 1'b0;
      if (push) begin
        q_valid[free_idx] <= 1'b1;
        q_write[free_idx] <= push_write;
        q_bank[free_idx]  <= addr_bank(push_addr);
        q_row[free_idx]   <= addr_row(push_addr);
        q_col[free_idx]   <= addr_col(push_addr);
        q_wdata[free_idx] <= push_wdata;
        q_tag[free_idx]   <= push_tag;
        q_wait[free_idx]  <= '0;
      end
    end
  end

endmodule
