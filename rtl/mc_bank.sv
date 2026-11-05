// One bank: its open row and the counters that gate its commands.
//
// Each counter holds the cycles left before a command is legal; 0 = legal on
// the next edge. An event loads at least (spec - 1), so the command that
// waits for it is sampled exactly spec edges later. Constraints combine by
// taking the larger remaining time.
`timescale 1ns/1ps

module mc_bank
  import dram_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                do_act,    // ACT to this bank on this edge
  input  logic                do_pre,    // PRE to this bank, or PREA while it is open
  input  logic                do_rd,
  input  logic                do_wr,
  input  logic [ROW_BITS-1:0] act_row,
  output logic                is_open,
  output logic [ROW_BITS-1:0] open_row,
  output logic                act_ok,    // closed, tRP and tRC met
  output logic                col_ok,    // open, tRCD met
  output logic                pre_ok     // open, tRAS, tRTP and write recovery met
);

  localparam int CW = 4;  // longest wait is tRC - 1 = 8

  logic [CW-1:0] act_wait, col_wait, pre_wait;

  function automatic logic [CW-1:0] dec(input logic [CW-1:0] v);
    return (v == '0) ? '0 : v - 1'b1;
  endfunction

  // Remaining time after this edge when a new rule of spec edges starts now.
  function automatic logic [CW-1:0] hold_for(input logic [CW-1:0] v, input int spec);
    return (int'(dec(v)) >= spec - 1) ? dec(v) : CW'(spec - 1);
  endfunction

  assign act_ok = !is_open && act_wait == '0;
  assign col_ok =  is_open && col_wait == '0;
  assign pre_ok =  is_open && pre_wait == '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      is_open  <= 1'b0;
      open_row <= '0;
      act_wait <= '0;
      col_wait <= '0;
      pre_wait <= '0;
    end else begin
      act_wait <= dec(act_wait);
      col_wait <= dec(col_wait);
      pre_wait <= dec(pre_wait);
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
      if (do_rd) pre_wait <= hold_for(pre_wait, tRTP);
      if (do_wr) pre_wait <= hold_for(pre_wait, WL + 1 + tWR);
    end
  end

endmodule
