// One bank: its open row and the counters that gate its commands.
//
// Each counter holds the cycles left before a command is legal; 0 = legal on
// the next edge. An event loads at least (spec - 1), so the command that
// waits for it is sampled exactly spec edges later. Constraints combine by
// taking the larger remaining time.
//
// Auto-precharge (do_ap with a RD/WR): the device precharges the bank by
// itself on the first edge a PRE would be legal (tRAS, tRTP, write recovery),
// so the next ACT waits that long plus tRP. The bank counts as closed at once.
//
// idle counts edges since the last ACT, RD or WR, up to PAGE_TIMEOUT
// (PAGE_TIMER policy).
`timescale 1ns/1ps

module mc_bank
  import dram_pkg::*;
#(
  parameter int PAGE_TIMEOUT = 16
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                do_act,    // ACT to this bank on this edge
  input  logic                do_pre,    // PRE to this bank, or PREA while it is open
  input  logic                do_rd,
  input  logic                do_wr,
  input  logic                do_ap,     // the RD/WR carries auto-precharge
  input  logic [ROW_BITS-1:0] act_row,
  output logic                is_open,
  output logic [ROW_BITS-1:0] open_row,
  output logic                act_ok,    // closed, tRP and tRC met
  output logic                col_ok,    // open, tRCD met
  output logic                pre_ok,    // open, tRAS, tRTP and write recovery met
  output logic                idle_long  // no ACT/RD/WR for PAGE_TIMEOUT edges
);

  localparam int CW = 4;  // longest wait is tRC - 1 = 8, or tRAS - 1 + tRP = 8 after auto-precharge
  localparam int IW = $clog2(PAGE_TIMEOUT + 1);

  logic [CW-1:0] act_wait, col_wait, pre_wait, pre_next;
  logic [IW-1:0] idle;

  function automatic logic [CW-1:0] dec(input logic [CW-1:0] v);
    return (v == '0) ? '0 : v - 1'b1;
  endfunction

  // Remaining time after this edge when a new rule of spec edges starts now.
  function automatic logic [CW-1:0] hold_for(input logic [CW-1:0] v, input int spec);
    return (int'(dec(v)) >= spec - 1) ? dec(v) : CW'(spec - 1);
  endfunction

  assign act_ok    = !is_open && act_wait == '0;
  assign col_ok    =  is_open && col_wait == '0;
  assign pre_ok    =  is_open && pre_wait == '0;
  assign idle_long = (idle == IW'(PAGE_TIMEOUT));

  // pre_wait after this edge: a RD or WR starts tRTP or write recovery
  always_comb begin
    pre_next = dec(pre_wait);
    if (do_rd) pre_next = hold_for(pre_wait, tRTP);
    if (do_wr) pre_next = hold_for(pre_wait, WL + 1 + tWR);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      is_open  <= 1'b0;
      open_row <= '0;
      act_wait <= '0;
      col_wait <= '0;
      pre_wait <= '0;
      idle     <= '0;
    end else begin
      act_wait <= dec(act_wait);
      col_wait <= dec(col_wait);
      pre_wait <= pre_next;
      if (do_act || do_rd || do_wr) idle <= '0;
      else if (idle != IW'(PAGE_TIMEOUT)) idle <= idle + 1'b1;
      if (do_act) begin
        is_open  <= 1'b1;
        open_row <= act_row;
        act_wait <= hold_for(act_wait, tRC);
        col_wait <= hold_for(col_wait, tRCD);
        pre_wait <= hold_for(pre_wait, tRAS);
      end
      if (do_pre) begin
        is_open  <= 1'b0;
        act_wait <= hold_for(act_wait, tRP);
      end
      // Internal precharge on edge pre_next + 1 from now, then tRP to the next ACT
      if ((do_rd || do_wr) && do_ap) begin
        is_open  <= 1'b0;
        act_wait <= (int'(dec(act_wait)) >= int'(pre_next) + tRP) ? dec(act_wait)
                                                                : CW'(int'(pre_next) + tRP);
      end
    end
  end

endmodule
