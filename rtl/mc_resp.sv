// Response side: response tags, the read-return FIFO, the write-data pipeline
// and the tag-ordered response buffer.
//
// Read data comes back in RD order (RL edges after its RD with this repo's
// DRAM model, later behind a slower PHY), so a FIFO of tags says whose data
// each data_valid carries; a read is done when its data
// arrives, or when it is accepted if mem_ctrl forwards it from the write
// queue. Writes are posted: a write is done when it is accepted. Write data
// goes out WL edges after its WR. The host sees responses in request order
// (tag_retire).
`timescale 1ns/1ps

module mc_resp
  import dram_pkg::*;
#(
  parameter int RD_PIPE = 4  // RDs allowed on the DRAM bus at once (1..4)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 acc,          // a request is accepted on this edge
  input  logic                 acc_write,    // ... and it is a write (answered now)
  input  logic                 acc_fwd,      // ... or a read answered from the write queue
  input  logic [DATA_BITS-1:0] fwd_data,
  output logic [TAG_BITS-1:0]  tag_alloc,    // tag the next accepted request gets
  output logic                 tag_free,     // fewer than 2^TAG_BITS - 1 in flight
  input  logic                 rd_issue,
  input  logic                 wr_issue,
  input  logic [TAG_BITS-1:0]  issue_tag,
  input  logic [DATA_BITS-1:0] issue_wdata,
  output logic                 rd_slot_ok,
  output logic                 dram_wdata_en,
  output logic [DATA_BITS-1:0] dram_wdata,
  input  logic                 dram_data_valid,
  input  logic [DATA_BITS-1:0] dram_rdata,
  output logic                 rsp_valid,
  input  logic                 rsp_ready,
  output logic [DATA_BITS-1:0] rsp_rdata
);

  localparam int TAG_N = 1 << TAG_BITS;
  localparam int RF_N  = 4;

  logic [TAG_BITS-1:0]  rf_tag [RF_N];
  logic [1:0]           rf_wp, rf_rp;
  logic [2:0]           rf_cnt;

  logic                 wp_v   [WL];
  logic [DATA_BITS-1:0] wp_d   [WL];

  logic [TAG_BITS-1:0]  tag_retire;  // oldest request not yet answered
  logic [TAG_BITS-1:0]  tag_next;
  logic                 done [TAG_N];
  logic [DATA_BITS-1:0] data [TAG_N];

  assign rd_slot_ok    = rf_cnt < 3'(RD_PIPE);
  assign tag_next      = tag_alloc + 1'b1;
  assign tag_free      = tag_next != tag_retire;
  assign dram_wdata_en = wp_v[WL-1];
  assign dram_wdata    = wp_d[WL-1];
  assign rsp_valid     = done[tag_retire];
  assign rsp_rdata     = data[tag_retire];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tag_alloc  <= '0;
      tag_retire <= '0;
      rf_wp      <= '0;
      rf_rp      <= '0;
      rf_cnt     <= '0;
      for (int i = 0; i < RF_N; i++) rf_tag[i] <= '0;
      for (int k = 0; k < WL; k++) begin
        wp_v[k] <= 1'b0;
        wp_d[k] <= '0;
      end
      for (int i = 0; i < TAG_N; i++) begin
        done[i] <= 1'b0;
        data[i] <= '0;
      end
    end else begin
      if (acc) tag_alloc <= tag_alloc + 1'b1;

      // Posted write (rsp_rdata = 0) or forwarded read: answered now
      if (acc && (acc_write || acc_fwd)) begin
        done[tag_alloc] <= 1'b1;
        data[tag_alloc] <= acc_write ? '0 : fwd_data;
      end

      // Read return
      if (rd_issue) begin
        rf_tag[rf_wp] <= issue_tag;
        rf_wp         <= rf_wp + 1'b1;
      end
      if (dram_data_valid) begin
        done[rf_tag[rf_rp]] <= 1'b1;
        data[rf_tag[rf_rp]] <= dram_rdata;
        rf_rp               <= rf_rp + 1'b1;
      end
      rf_cnt <= rf_cnt + 3'(rd_issue) - 3'(dram_data_valid);

      // Write data, WL edges after the WR
      wp_v[0] <= wr_issue;
      wp_d[0] <= issue_wdata;
      for (int k = 1; k < WL; k++) begin
        wp_v[k] <= wp_v[k-1];
        wp_d[k] <= wp_d[k-1];
      end

      // In-order responses
      if (rsp_valid && rsp_ready) begin
        done[tag_retire] <= 1'b0;
        tag_retire       <= tag_retire + 1'b1;
      end
    end
  end

endmodule
