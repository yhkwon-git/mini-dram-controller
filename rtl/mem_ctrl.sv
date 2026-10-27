// Mini memory controller — timing FSM + refresh slot (docs/spec.md).
`timescale 1ns/1ps

module mem_ctrl
  import dram_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic                 req_valid,
  output logic                 req_ready,
  input  logic                 req_write,
  input  logic [ADDR_BITS-1:0] req_addr,
  input  logic [DATA_BITS-1:0] req_wdata,

  output logic                 rsp_valid,
  input  logic                 rsp_ready,
  output logic [DATA_BITS-1:0] rsp_rdata,
  output logic                 rsp_err,

  output dram_cmd_e            dram_cmd,
  output logic [$clog2(NUM_BANKS)-1:0] dram_bank,
  output logic [ROW_BITS-1:0]  dram_row,
  output logic [COL_BITS-1:0]  dram_col,
  output logic [DATA_BITS-1:0] dram_wdata,

  input  logic                 dram_busy,
  input  logic                 dram_data_valid,
  input  logic [DATA_BITS-1:0] dram_rdata,
  input  logic                 dram_page_hit
);

  ctrl_state_e state, state_n;

  logic [ADDR_BITS-1:0] latched_addr;
  logic [DATA_BITS-1:0] latched_wdata;
  logic                 latched_write;

  // Generic wait counter (tRCD / tRP / tWR)
  logic [7:0] timer;
  logic       load_timer;
  logic [7:0] timer_init;

  logic [$clog2(tREFI+1)-1:0] refi_cnt;

  // Shadow open-page + tRAS / tRC remainders (controller view)
  logic                          bank_open [NUM_BANKS];
  logic [ROW_BITS-1:0]           bank_row  [NUM_BANKS];
  logic [$clog2(tRAS+1)-1:0]     ras_rem   [NUM_BANKS];
  logic [$clog2(tRC+1)-1:0]      rc_rem    [NUM_BANKS];

  // After PRE for page-miss, continue to ACT
  logic need_act_after_pre, need_act_after_pre_n;

  logic [$clog2(NUM_BANKS)-1:0] sel_bank;
  logic [ROW_BITS-1:0]          sel_row;
  logic [COL_BITS-1:0]          sel_col;

  logic page_hit_now;
  logic bank_is_open;
  logic accept;

  assign sel_bank = addr_bank(latched_addr);
  assign sel_row  = addr_row(latched_addr);
  assign sel_col  = addr_col(latched_addr);

  // -------------------------------------------------------------------------
  // Sequential
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state              <= ST_IDLE;
      latched_addr       <= '0;
      latched_wdata      <= '0;
      latched_write      <= 1'b0;
      timer              <= '0;
      refi_cnt           <= tREFI[$bits(refi_cnt)-1:0];
      need_act_after_pre <= 1'b0;
      for (int i = 0; i < NUM_BANKS; i++) begin
        bank_open[i] <= 1'b0;
        bank_row[i]  <= '0;
        ras_rem[i]   <= '0;
        rc_rem[i]    <= '0;
      end
    end else begin
      state              <= state_n;
      need_act_after_pre <= need_act_after_pre_n;

      if (accept) begin
        latched_addr  <= req_addr;
        latched_wdata <= req_wdata;
        latched_write <= req_write;
      end

      if (load_timer)
        timer <= timer_init;
      else if (timer != 0)
        timer <= timer - 8'd1;

      // Refresh interval: count down; reload when REF completes
      if (state == ST_REF_WAIT && state_n == ST_IDLE)
        refi_cnt <= tREFI[$bits(refi_cnt)-1:0];
      else if (refi_cnt != 0)
        refi_cnt <= refi_cnt - 1'b1;

      // Per-bank RAS / RC countdowns
      for (int i = 0; i < NUM_BANKS; i++) begin
        if (ras_rem[i] != 0)
          ras_rem[i] <= ras_rem[i] - 1'b1;
        if (rc_rem[i] != 0)
          rc_rem[i] <= rc_rem[i] - 1'b1;
      end

      // Update open-page shadow when we issue commands
      if (state == ST_ACT) begin
        bank_open[sel_bank] <= 1'b1;
        bank_row[sel_bank]  <= sel_row;
        ras_rem[sel_bank]   <= tRAS[$bits(ras_rem[0])-1:0];
        rc_rem[sel_bank]    <= tRC[$bits(rc_rem[0])-1:0];
      end

      if (state == ST_PRE && ras_rem[sel_bank] == 0) begin
        bank_open[sel_bank] <= 1'b0;
      end

      if (state == ST_REF) begin
        for (int i = 0; i < NUM_BANKS; i++) begin
          bank_open[i] <= 1'b0;
          ras_rem[i]   <= '0;
          rc_rem[i]    <= '0;
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Combinational FSM
  // -------------------------------------------------------------------------
  always_comb begin
    state_n              = state;
    need_act_after_pre_n = need_act_after_pre;
    req_ready            = 1'b0;
    rsp_valid            = 1'b0;
    rsp_rdata            = dram_rdata;
    rsp_err              = 1'b0;
    dram_cmd             = CMD_NOP;
    dram_bank            = sel_bank;
    dram_row             = sel_row;
    dram_col             = sel_col;
    dram_wdata           = latched_wdata;
    load_timer           = 1'b0;
    timer_init           = '0;
    accept               = 1'b0;

    page_hit_now = 1'b0;
    bank_is_open = 1'b0;

    unique case (state)
      // -----------------------------------------------------------------
      ST_IDLE: begin
        need_act_after_pre_n = 1'b0;
        if (refi_cnt == 0 && !dram_busy) begin
          state_n = ST_REF;
        end else if (req_valid && !dram_busy && refi_cnt != 0) begin
          req_ready = 1'b1;
          accept    = 1'b1;
          // Decide path from request address (latched next cycle)
          bank_is_open = bank_open[addr_bank(req_addr)];
          page_hit_now = bank_is_open &&
                         (bank_row[addr_bank(req_addr)] == addr_row(req_addr));
          if (page_hit_now) begin
            state_n = req_write ? ST_WR : ST_RD;
          end else if (bank_is_open) begin
            need_act_after_pre_n = 1'b1;
            state_n              = ST_PRE;
          end else begin
            state_n = ST_ACT;
          end
        end
      end

      // -----------------------------------------------------------------
      ST_ACT: begin
        // Wait out tRC for same bank if needed
        if (rc_rem[sel_bank] == 0) begin
          dram_cmd   = CMD_ACT;
          load_timer = 1'b1;
          // tRCD-1 so RD/WR issues exactly tRCD cycles after ACT
          timer_init = 8'(tRCD > 0 ? tRCD - 1 : 0);
          state_n    = ST_ACT_WAIT;
        end
      end

      ST_ACT_WAIT: begin
        if (timer == 0) begin
          // Issue RD/WR in this cycle (ACT → CAS == tRCD)
          if (latched_write) begin
            dram_cmd   = CMD_WR;
            dram_wdata = latched_wdata;
            load_timer = 1'b1;
            timer_init = 8'(tWR > 0 ? tWR - 1 : 0);
            state_n    = ST_WR_WAIT;
          end else begin
            dram_cmd = CMD_RD;
            state_n  = ST_RD_WAIT;
          end
        end
      end

      // -----------------------------------------------------------------
      ST_RD: begin
        dram_cmd = CMD_RD;
        state_n  = ST_RD_WAIT;
      end

      ST_RD_WAIT: begin
        if (dram_data_valid) begin
          rsp_valid = 1'b1;
          rsp_rdata = dram_rdata;
          if (rsp_ready)
            state_n = ST_IDLE; // leave row open (hit reuse)
        end
      end

      // -----------------------------------------------------------------
      ST_WR: begin
        dram_cmd   = CMD_WR;
        dram_wdata = latched_wdata;
        load_timer = 1'b1;
        timer_init = 8'(tWR > 0 ? tWR - 1 : 0);
        state_n    = ST_WR_WAIT;
      end

      ST_WR_WAIT: begin
        if (timer == 0) begin
          rsp_valid = 1'b1;
          rsp_rdata = '0;
          if (rsp_ready)
            state_n = ST_IDLE;
        end
      end

      // -----------------------------------------------------------------
      ST_PRE: begin
        if (ras_rem[sel_bank] == 0) begin
          dram_cmd   = CMD_PRE;
          load_timer = 1'b1;
          timer_init = 8'(tRP > 0 ? tRP - 1 : 0);
          state_n    = ST_PRE_WAIT;
        end
        // else hold until tRAS satisfied
      end

      ST_PRE_WAIT: begin
        if (timer == 0) begin
          if (need_act_after_pre) begin
            need_act_after_pre_n = 1'b0;
            state_n              = ST_ACT;
          end else begin
            state_n = ST_IDLE;
          end
        end
      end

      // -----------------------------------------------------------------
      ST_REF: begin
        dram_cmd = CMD_REF;
        state_n  = ST_REF_WAIT;
      end

      ST_REF_WAIT: begin
        if (!dram_busy)
          state_n = ST_IDLE;
      end

      ST_ERROR: begin
        state_n = ST_ERROR;
      end

      default: state_n = ST_IDLE;
    endcase

    // Silence unused model hint (policy uses local shadow)
    // dram_page_hit available for debug/waves
  end

  // Keep dram_page_hit referenced for waves / lint
  logic unused_page_hit;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) unused_page_hit <= 1'b0;
    else        unused_page_hit <= dram_page_hit;
  end

endmodule
