// Refresh bookkeeping, all-bank or per-bank.
//
// MODE = REF_ALL: one REF is owed every tREFI cycles whatever the traffic
// does, so the average REF interval is tREFI by construction. The controller
// pays a REF back when the queues are empty, or at once when URGENT REFs are
// owed. hold stays high from that decision until the REF issues; while it is
// high the scheduler opens no row and issues no RD/WR, only PREA and REF.
//
// MODE = REF_BANK: one REFpb is owed every tREFIpb = tREFI / NUM_BANKS
// cycles, and the banks take turns (bank), so each bank still gets one
// refresh per tREFI. A REFpb is paid back when no queued request needs that
// bank, or at once when URGENT are owed. hold then applies to that bank only:
// no ACT and no RD/WR to it, PRE if it is open, then REFpb. The other banks
// keep working.
`timescale 1ns/1ps

module mc_refresh
  import dram_pkg::*;
#(
  parameter int URGENT = 4,       // owed refreshes that stop new traffic
  parameter int MODE   = REF_ALL
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 idle,     // no request waiting in either queue
  input  logic [NUM_BANKS-1:0] wanted,   // banks a queued request needs
  input  logic                 do_ref,   // REF (REF_ALL) or REFpb (REF_BANK) issued on this edge
  output logic                 hold,
  output logic [BANK_BITS-1:0] bank,     // REF_BANK: the bank to refresh next
  output logic [3:0]           owed
);

  localparam int PERIOD = (MODE == REF_BANK) ? tREFIpb : tREFI;
  localparam int RW     = $clog2(PERIOD);

  logic [RW-1:0] refi;
  logic          tick;
  logic          busy_q;
  logic          start;
  logic          quiet;   // nothing needs what the next refresh blocks

  assign tick  = (refi == '0);
  assign quiet = (MODE == REF_BANK) ? !wanted[bank] : idle;
  assign start = (owed != '0) && (quiet || owed >= 4'(URGENT));
  assign hold  = busy_q || start;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      refi   <= RW'(PERIOD - 1);
      owed   <= '0;
      busy_q <= 1'b0;
      bank   <= '0;
    end else begin
      refi <= tick ? RW'(PERIOD - 1) : refi - 1'b1;
      if (tick && !do_ref)
        owed <= (owed == 4'hF) ? owed : owed + 1'b1;
      else if (!tick && do_ref)
        owed <= owed - 1'b1;
      busy_q <= hold && !do_ref;
      if (MODE == REF_BANK && do_ref) bank <= bank + 1'b1;
    end
  end

endmodule
