// Age between the two queues: w_older_r[w][r] = 1 when write-queue entry w
// was accepted before read-queue entry r. With the age matrix inside each
// queue this orders any read against any write, which the scheduler needs
// only when reads and writes compete (WDRAIN = 0, FCFS guard, starvation).
//
// A pushed read is younger than every write already queued; a pushed write is
// younger than every queued read. Bits of an empty entry are rewritten when a
// request takes it, so a pop needs no update.
`timescale 1ns/1ps

module mc_xage
  import dram_pkg::*;
#(
  parameter int DEPTH = QUEUE_DEPTH
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         push_rd,
  input  logic                         push_wr,
  input  logic [$clog2(DEPTH)-1:0]     slot,      // the entry the push takes
  input  logic [DEPTH-1:0]             wq_valid,
  output logic [DEPTH-1:0][DEPTH-1:0]  w_older_r  // [w][r]
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_older_r <= '0;
    end else begin
      for (int k = 0; k < DEPTH; k++) begin
        if (push_rd) w_older_r[k][slot] <= wq_valid[k];
        if (push_wr) w_older_r[slot][k] <= 1'b0;
      end
    end
  end

endmodule
