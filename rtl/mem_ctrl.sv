// Mini memory controller skeleton: host req -> (future scheduler) -> DRAM cmds.
// Educational own-spec ONLY. Not JEDEC or HBM compliant.
`timescale 1ns/1ps

module mem_ctrl
  import dram_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  // Host side
  input  logic              req_valid,
  output logic              req_ready,
  input  logic              req_write,
  input  logic [ADDR_BITS-1:0] req_addr,
  input  logic [DATA_BITS-1:0] req_wdata,

  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [DATA_BITS-1:0] rsp_rdata,
  output logic              rsp_err,

  // DRAM model side
  output dram_cmd_e         dram_cmd,
  output logic [$clog2(NUM_BANKS)-1:0] dram_bank,
  output logic [ROW_BITS-1:0] dram_row,
  output logic [COL_BITS-1:0] dram_col,
  output logic [DATA_BITS-1:0] dram_wdata,

  input  logic              dram_busy,
  input  logic              dram_data_valid,
  input  logic [DATA_BITS-1:0] dram_rdata,
  input  logic              dram_page_hit
);

  ctrl_state_e state, state_n;

  logic [ADDR_BITS-1:0] latched_addr;
  logic [DATA_BITS-1:0] latched_wdata;
  logic                 latched_write;
  logic [$clog2(tREFI+1)-1:0] refi_cnt;

  // -------------------------------------------------------------------------
  // State register
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= ST_IDLE;
      latched_addr  <= '0;
      latched_wdata <= '0;
      latched_write <= 1'b0;
      refi_cnt      <= tREFI[$bits(refi_cnt)-1:0];
    end else begin
      state <= state_n;
      if (state == ST_IDLE && req_valid && req_ready) begin
        latched_addr  <= req_addr;
        latched_wdata <= req_wdata;
        latched_write <= req_write;
      end
      // Placeholder refresh countdown — real slot arbitration TODO
      if (refi_cnt != 0)
        refi_cnt <= refi_cnt - 1'b1;
      else if (state == ST_REF_WAIT && !dram_busy)
        refi_cnt <= tREFI[$bits(refi_cnt)-1:0];
    end
  end

  // -------------------------------------------------------------------------
  // Next-state / outputs — skeleton only (NOP most of the time)
  // Full ACT/RD/WR/PRE/REF scheduler is intentionally NOT implemented yet.
  // -------------------------------------------------------------------------
  always_comb begin
    state_n    = state;
    req_ready  = 1'b0;
    rsp_valid  = 1'b0;
    rsp_rdata  = '0;
    rsp_err    = 1'b0;
    dram_cmd   = CMD_NOP;
    dram_bank  = addr_bank(latched_addr);
    dram_row   = addr_row(latched_addr);
    dram_col   = addr_col(latched_addr);
    dram_wdata = latched_wdata;

    unique case (state)
      ST_IDLE: begin
        // Prefer refresh slot when counter expires (stub path)
        if (refi_cnt == 0) begin
          state_n  = ST_REF;
        end else if (req_valid && !dram_busy) begin
          req_ready = 1'b1;
          // TODO: bank conflict / page hit-miss decision
          state_n   = ST_ACT; // jump to ACT skeleton; real schedule later
        end
      end

      ST_ACT: begin
        dram_cmd = CMD_ACT;
        state_n  = ST_ACT_WAIT;
      end

      ST_ACT_WAIT: begin
        // TODO: wait tRCD
        state_n = latched_write ? ST_WR : ST_RD;
      end

      ST_RD: begin
        dram_cmd = CMD_RD;
        state_n  = ST_RD_WAIT;
      end

      ST_RD_WAIT: begin
        if (dram_data_valid) begin
          rsp_valid = 1'b1;
          rsp_rdata = dram_rdata;
          if (rsp_ready)
            state_n = ST_IDLE; // TODO: optional auto-PRE
        end
      end

      ST_WR: begin
        dram_cmd   = CMD_WR;
        dram_wdata = latched_wdata;
        state_n    = ST_WR_WAIT;
      end

      ST_WR_WAIT: begin
        // TODO: tWR then optional PRE
        rsp_valid = 1'b1;
        rsp_rdata = '0;
        if (rsp_ready)
          state_n = ST_IDLE;
      end

      ST_PRE: begin
        dram_cmd = CMD_PRE;
        state_n  = ST_PRE_WAIT;
      end

      ST_PRE_WAIT: begin
        // TODO: wait tRP
        state_n = ST_IDLE;
      end

      ST_REF: begin
        dram_cmd = CMD_REF;
        state_n  = ST_REF_WAIT;
      end

      ST_REF_WAIT: begin
        if (!dram_busy)
          state_n = ST_IDLE;
      end

      default: state_n = ST_IDLE;
    endcase
  end

  // Skeleton: latch page_hit for future scheduler policy (bank conflict / prefer hit)
  logic page_hit_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) page_hit_q <= 1'b0;
    else        page_hit_q <= dram_page_hit;
  end

endmodule
