// Channel-wide command spacing: tCCD, tRRD, tFAW, tWTR, tRTW, and the tRFC
// blackout after REF. Same counter convention as mc_bank.
//
// tFAW keeps one counter per ACT in the window. An ACT needs a counter that
// has run out, which means the oldest of the last four ACTs is tFAW old.
`timescale 1ns/1ps

module mc_chan
  import dram_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic do_act,
  input  logic do_rd,
  input  logic do_wr,
  input  logic do_ref,
  output logic act_ok,
  output logic rd_ok,
  output logic wr_ok,
  output logic any_ok   // PRE, PREA, REF: only the tRFC blackout applies
);

  localparam int CW = 5;  // longest wait is tRFC - 1 = 11

  logic [CW-1:0] ccd_wait, rrd_wait, wtr_wait, rtw_wait, rfc_wait;
  logic [CW-1:0] faw_wait [4];
  logic          faw_free;
  logic [1:0]    faw_slot;

  function automatic logic [CW-1:0] dec(input logic [CW-1:0] v);
    return (v == '0) ? '0 : v - 1'b1;
  endfunction

  function automatic logic [CW-1:0] hold_for(input logic [CW-1:0] v, input int spec);
    return (int'(dec(v)) >= spec - 1) ? dec(v) : CW'(spec - 1);
  endfunction

  always_comb begin
    faw_free = 1'b0;
    faw_slot = 2'd0;
    for (int i = 3; i >= 0; i--) begin
      if (faw_wait[i] == '0) begin
        faw_free = 1'b1;
        faw_slot = 2'(i);
      end
    end
  end

  assign any_ok = (rfc_wait == '0);
  assign act_ok = any_ok && rrd_wait == '0 && faw_free;
  assign rd_ok  = any_ok && ccd_wait == '0 && wtr_wait == '0;
  assign wr_ok  = any_ok && ccd_wait == '0 && rtw_wait == '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ccd_wait <= '0;
      rrd_wait <= '0;
      wtr_wait <= '0;
      rtw_wait <= '0;
      rfc_wait <= '0;
      for (int i = 0; i < 4; i++) faw_wait[i] <= '0;
    end else begin
      ccd_wait <= (do_rd || do_wr) ? hold_for(ccd_wait, tCCD) : dec(ccd_wait);
      rrd_wait <= do_act ? hold_for(rrd_wait, tRRD) : dec(rrd_wait);
      wtr_wait <= do_wr  ? hold_for(wtr_wait, tWTR) : dec(wtr_wait);
      rtw_wait <= do_rd  ? hold_for(rtw_wait, tRTW) : dec(rtw_wait);
      rfc_wait <= do_ref ? hold_for(rfc_wait, tRFC) : dec(rfc_wait);
      for (int i = 0; i < 4; i++) faw_wait[i] <= dec(faw_wait[i]);
      if (do_act) faw_wait[faw_slot] <= CW'(tFAW - 1);
    end
  end

endmodule
