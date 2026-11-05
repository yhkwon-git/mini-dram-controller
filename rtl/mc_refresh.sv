// Refresh bookkeeping.
//
// One REF is owed every tREFI cycles whatever the traffic does, so the
// average REF interval is tREFI by construction. The controller pays a REF
// back when the queue is empty, or at once when URGENT REFs are owed. Either
// way the sequence runs to the end: hold stays high from the decision until
// the REF is issued, and while it is high the scheduler opens no row and
// issues no RD/WR, only PREA and then REF.
`timescale 1ns/1ps

module mc_refresh
  import dram_pkg::*;
#(
  parameter int URGENT = 4  // owed REFs that stop new traffic
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       idle,    // no request waiting in the queue
  input  logic       do_ref,  // REF issued on this edge
  output logic       hold,
  output logic [3:0] owed
);

  localparam int RW = $clog2(tREFI);

  logic [RW-1:0] refi;
  logic          tick;
  logic          busy_q;
  logic          start;

  assign tick  = (refi == '0);
  assign start = (owed != '0) && (idle || owed >= 4'(URGENT));
  assign hold  = busy_q || start;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      refi   <= RW'(tREFI - 1);
      owed   <= '0;
      busy_q <= 1'b0;
    end else begin
      refi <= tick ? RW'(tREFI - 1) : refi - 1'b1;
      if (tick && !do_ref)
        owed <= (owed == 4'hF) ? owed : owed + 1'b1;
      else if (!tick && do_ref)
        owed <= owed - 1'b1;
      busy_q <= hold && !do_ref;
    end
  end

endmodule
