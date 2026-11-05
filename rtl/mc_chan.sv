// Channel-wide command spacing with bank groups, and the tRFC blackout after
// an all-bank REF. Same counter convention as mc_bank.
//
//   tCCD_S / tCCD_L  RD/WR -> RD/WR, other / same bank group
//   tRRD_S / tRRD_L  ACT -> ACT, other / same bank group; a REFpb counts as an
//                    ACT for tRRD_S
//   tWTR_S / tWTR_L  WR -> RD, other / same bank group
//   tRTW             RD -> WR
//   tFAW             an ACT needs a counter that has run out: the oldest of the
//                    last four ACTs is tFAW old
//   tRFC             no command after an all-bank REF
//
// The ACT, RD and WR outputs are per bank group. The row bus (ACT, REFpb) and
// the column bus (RD, WR) may both issue on one edge.
`timescale 1ns/1ps

module mc_chan
  import dram_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,
  input  logic               do_act,    // row bus
  input  logic               do_refpb,
  input  logic [BG_BITS-1:0] row_bg,
  input  logic               do_rd,     // column bus
  input  logic               do_wr,
  input  logic [BG_BITS-1:0] col_bg,
  input  logic               do_ref,
  output logic [NUM_BG-1:0]  act_ok,
  output logic [NUM_BG-1:0]  rd_ok,
  output logic [NUM_BG-1:0]  wr_ok,
  output logic               refpb_ok,
  output logic               any_ok     // PRE, PREA, REF: only the tRFC blackout applies
);

  localparam int CW = 5;  // longest wait is tRFC - 1 = 11

  logic [CW-1:0]             ccd_s, rrd_s, wtr_s, rtw, rfc;
  logic [NUM_BG-1:0][CW-1:0] ccd_l, rrd_l, wtr_l;
  logic [CW-1:0]             faw_wait [4];
  logic                      faw_free;
  logic [1:0]                faw_slot;

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

  assign any_ok   = (rfc == '0);
  assign refpb_ok = any_ok && rrd_s == '0;
  for (genvar g = 0; g < NUM_BG; g++) begin : g_bg
    assign act_ok[g] = any_ok && rrd_s == '0 && rrd_l[g] == '0 && faw_free;
    assign rd_ok[g]  = any_ok && ccd_s == '0 && ccd_l[g] == '0 && wtr_s == '0 && wtr_l[g] == '0;
    assign wr_ok[g]  = any_ok && ccd_s == '0 && ccd_l[g] == '0 && rtw == '0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ccd_s <= '0;
      rrd_s <= '0;
      wtr_s <= '0;
      rtw   <= '0;
      rfc   <= '0;
      ccd_l <= '0;
      rrd_l <= '0;
      wtr_l <= '0;
      for (int i = 0; i < 4; i++) faw_wait[i] <= '0;
    end else begin
      ccd_s <= (do_rd || do_wr)     ? hold_for(ccd_s, tCCD_S) : dec(ccd_s);
      rrd_s <= (do_act || do_refpb) ? hold_for(rrd_s, tRRD_S) : dec(rrd_s);
      wtr_s <= do_wr                ? hold_for(wtr_s, tWTR_S) : dec(wtr_s);
      rtw   <= do_rd                ? hold_for(rtw, tRTW)     : dec(rtw);
      rfc   <= do_ref               ? hold_for(rfc, tRFC)     : dec(rfc);
      for (int g = 0; g < NUM_BG; g++) begin
        ccd_l[g] <= ((do_rd || do_wr) && col_bg == BG_BITS'(g)) ? hold_for(ccd_l[g], tCCD_L) : dec(ccd_l[g]);
        rrd_l[g] <= (do_act && row_bg == BG_BITS'(g))           ? hold_for(rrd_l[g], tRRD_L) : dec(rrd_l[g]);
        wtr_l[g] <= (do_wr && col_bg == BG_BITS'(g))            ? hold_for(wtr_l[g], tWTR_L) : dec(wtr_l[g]);
      end
      for (int i = 0; i < 4; i++) faw_wait[i] <= dec(faw_wait[i]);
      if (do_act) faw_wait[faw_slot] <= CW'(tFAW - 1);
    end
  end

endmodule
