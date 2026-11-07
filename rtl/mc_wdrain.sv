// Read/write mode for the scheduler (WDRAIN = 1). Each RD<->WR switch on the
// data bus costs tWTR or tRTW, so writes wait in their queue and go out in
// batches:
//
//   read mode   the default; only reads are scheduled
//   write mode  when the write queue reaches WR_HI, until it is down to WR_LO
//               (a drain); also whenever no read is queued, and while a write
//               has waited STARVE_LIMIT cycles
//
// The mode sets priority, not a ban: mc_sched still issues a command for the
// other queue when nothing in the selected one is ready.
//
// wmode is registered: it follows the queues one cycle late, which keeps the
// counts off the scheduler's path.
`timescale 1ns/1ps

module mc_wdrain
  import dram_pkg::*;
#(
  parameter int DEPTH = QUEUE_DEPTH,
  parameter int WR_HI = 6,
  parameter int WR_LO = 2
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [DEPTH-1:0] rq_valid,
  input  logic [DEPTH-1:0] wq_valid,
  input  logic             w_starve,  // a queued write has waited STARVE_LIMIT cycles
  output logic             wmode
);

  localparam int CW = $clog2(DEPTH + 1);
  localparam int LO_I = WR_LO;
  localparam int HI_I = WR_HI;
  localparam logic [CW-1:0] LO = LO_I[CW-1:0];
  localparam logic [CW-1:0] HI = HI_I[CW-1:0];

  logic [CW-1:0] n_wr;
  logic          drain, drain_next;

  always_comb begin
    n_wr = '0;
    for (int i = 0; i < DEPTH; i++) n_wr += {{(CW-1){1'b0}}, wq_valid[i]};
    drain_next = drain ? (n_wr > LO) : (n_wr >= HI);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drain <= 1'b0;
      wmode <= 1'b0;
    end else begin
      drain <= drain_next;
      wmode <= (wq_valid != '0) && (drain_next || w_starve || rq_valid == '0);
    end
  end

endmodule
