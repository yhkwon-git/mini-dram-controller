// Mini memory controller — depth-4 request queue + per-bank parallel timing.
// One DRAM command per cycle; bank timers advance concurrently (docs/spec.md).
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

  localparam int TAG_BITS = 4;
  localparam int TAG_N    = 1 << TAG_BITS;

  // -------------------------------------------------------------------------
  // Request queue slots (valid-bit CAM-style; bank-aware dispatch)
  // -------------------------------------------------------------------------
  logic                 q_valid [QUEUE_DEPTH];
  logic [ADDR_BITS-1:0] q_addr  [QUEUE_DEPTH];
  logic [DATA_BITS-1:0] q_wdata [QUEUE_DEPTH];
  logic                 q_write [QUEUE_DEPTH];
  logic [TAG_BITS-1:0]  q_tag   [QUEUE_DEPTH];
  logic [QUEUE_AW:0]    q_count;
  logic [QUEUE_AW-1:0]  free_slot;
  logic                 free_found;

  logic [TAG_BITS-1:0]  tag_alloc, tag_retire;
  logic                 rsp_done [TAG_N];
  logic [DATA_BITS-1:0] rsp_data [TAG_N];

  ctrl_state_e               b_state [NUM_BANKS];
  logic [ADDR_BITS-1:0]      b_addr  [NUM_BANKS];
  logic [DATA_BITS-1:0]      b_wdata [NUM_BANKS];
  logic                      b_write [NUM_BANKS];
  logic [TAG_BITS-1:0]       b_tag   [NUM_BANKS];
  logic [7:0]                b_timer [NUM_BANKS];
  logic                      b_need_act [NUM_BANKS];

  logic                      bank_open [NUM_BANKS];
  logic [ROW_BITS-1:0]       bank_row  [NUM_BANKS];
  logic [$clog2(tRAS+1)-1:0] ras_rem   [NUM_BANKS];
  logic [$clog2(tRC+1)-1:0]  rc_rem    [NUM_BANKS];

  logic [$clog2(tREFI+1)-1:0] refi_cnt;
  logic                       ref_active, ref_issue, ref_due, all_banks_idle;

  logic                       rd_inflight;
  logic [$clog2(NUM_BANKS)-1:0] rd_bank_q;

  logic want_pre [NUM_BANKS], want_act [NUM_BANKS], want_rd [NUM_BANKS], want_wr [NUM_BANKS];
  logic [$clog2(NUM_BANKS)-1:0] rr_ptr, win_bank;
  logic                       win_valid;
  dram_cmd_e                  win_cmd;

  logic                       disp_valid;
  logic [$clog2(NUM_BANKS)-1:0] disp_bank;
  logic [QUEUE_AW-1:0]        disp_slot;
  logic                       q_push;

  integer bi;

  always_comb begin
    all_banks_idle = 1'b1;
    for (bi = 0; bi < NUM_BANKS; bi++) begin
      want_pre[bi] = 1'b0;
      want_act[bi] = 1'b0;
      want_rd[bi]  = 1'b0;
      want_wr[bi]  = 1'b0;
      if (b_state[bi] != ST_IDLE) all_banks_idle = 1'b0;
      case (b_state[bi])
        ST_PRE: want_pre[bi] = (ras_rem[bi] == 0);
        ST_ACT: want_act[bi] = (rc_rem[bi] == 0);
        ST_RD:  want_rd[bi]  = 1'b1;
        ST_WR:  want_wr[bi]  = 1'b1;
        default: ;
      endcase
    end

    ref_due   = (refi_cnt == 0);
    ref_issue = ref_due && !ref_active && all_banks_idle && (q_count == 0) && !dram_busy;

    free_found = 1'b0;
    free_slot  = '0;
    for (bi = 0; bi < QUEUE_DEPTH; bi++) begin
      if (!q_valid[bi] && !free_found) begin
        free_found = 1'b1;
        free_slot  = bi[QUEUE_AW-1:0];
      end
    end

    req_ready = free_found && !ref_due && !ref_active;
    q_push    = req_valid && req_ready;

    // Prefer oldest tag among ready-to-dispatch entries
    disp_valid = 1'b0;
    disp_bank  = '0;
    disp_slot  = '0;
    if (!ref_active && !ref_issue) begin
      for (bi = 0; bi < QUEUE_DEPTH; bi++) begin
        if (q_valid[bi] && (b_state[addr_bank(q_addr[bi])] == ST_IDLE)) begin
          if (!disp_valid || (q_tag[bi] - tag_retire) < (q_tag[disp_slot] - tag_retire)) begin
            disp_valid = 1'b1;
            disp_bank  = addr_bank(q_addr[bi]);
            disp_slot  = bi[QUEUE_AW-1:0];
          end
        end
      end
    end

    win_valid = 1'b0;
    win_bank  = '0;
    win_cmd   = CMD_NOP;
    if (!dram_busy && !ref_active && !ref_issue) begin
      for (bi = 0; bi < NUM_BANKS; bi++) begin
        automatic int b = (int'(rr_ptr) + bi) % NUM_BANKS;
        if (!win_valid && want_pre[b]) begin
          win_valid = 1'b1; win_bank = b[$clog2(NUM_BANKS)-1:0]; win_cmd = CMD_PRE;
        end
      end
      for (bi = 0; bi < NUM_BANKS; bi++) begin
        automatic int b = (int'(rr_ptr) + bi) % NUM_BANKS;
        if (!win_valid && want_act[b]) begin
          win_valid = 1'b1; win_bank = b[$clog2(NUM_BANKS)-1:0]; win_cmd = CMD_ACT;
        end
      end
      for (bi = 0; bi < NUM_BANKS; bi++) begin
        automatic int b = (int'(rr_ptr) + bi) % NUM_BANKS;
        if (!win_valid && want_wr[b]) begin
          win_valid = 1'b1; win_bank = b[$clog2(NUM_BANKS)-1:0]; win_cmd = CMD_WR;
        end
      end
      for (bi = 0; bi < NUM_BANKS; bi++) begin
        automatic int b = (int'(rr_ptr) + bi) % NUM_BANKS;
        if (!win_valid && want_rd[b] && !rd_inflight) begin
          win_valid = 1'b1; win_bank = b[$clog2(NUM_BANKS)-1:0]; win_cmd = CMD_RD;
        end
      end
    end

    dram_cmd   = CMD_NOP;
    dram_bank  = '0;
    dram_row   = '0;
    dram_col   = '0;
    dram_wdata = '0;
    if (ref_issue) begin
      dram_cmd = CMD_REF;
    end else if (win_valid) begin
      dram_cmd   = win_cmd;
      dram_bank  = win_bank;
      dram_row   = addr_row(b_addr[win_bank]);
      dram_col   = addr_col(b_addr[win_bank]);
      dram_wdata = b_wdata[win_bank];
    end

    rsp_err   = 1'b0;
    rsp_valid = rsp_done[tag_retire];
    rsp_rdata = rsp_data[tag_retire];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_count     <= '0;
      tag_alloc   <= '0;
      tag_retire  <= '0;
      refi_cnt    <= tREFI[$bits(refi_cnt)-1:0];
      ref_active  <= 1'b0;
      rr_ptr      <= '0;
      rd_inflight <= 1'b0;
      rd_bank_q   <= '0;
      for (int i = 0; i < QUEUE_DEPTH; i++) begin
        q_valid[i] <= 1'b0;
        q_addr[i]  <= '0;
        q_wdata[i] <= '0;
        q_write[i] <= 1'b0;
        q_tag[i]   <= '0;
      end
      for (int i = 0; i < TAG_N; i++) begin
        rsp_done[i] <= 1'b0;
        rsp_data[i] <= '0;
      end
      for (int i = 0; i < NUM_BANKS; i++) begin
        b_state[i]    <= ST_IDLE;
        b_addr[i]     <= '0;
        b_wdata[i]    <= '0;
        b_write[i]    <= 1'b0;
        b_tag[i]      <= '0;
        b_timer[i]    <= '0;
        b_need_act[i] <= 1'b0;
        bank_open[i]  <= 1'b0;
        bank_row[i]   <= '0;
        ras_rem[i]    <= '0;
        rc_rem[i]     <= '0;
      end
    end else begin
      // Refresh
      if (ref_active) begin
        if (!dram_busy) begin
          ref_active <= 1'b0;
          refi_cnt   <= tREFI[$bits(refi_cnt)-1:0];
        end
      end else if (refi_cnt != 0) begin
        refi_cnt <= refi_cnt - 1'b1;
      end

      if (ref_issue) begin
        ref_active <= 1'b1;
        for (int i = 0; i < NUM_BANKS; i++) begin
          bank_open[i] <= 1'b0;
          ras_rem[i]   <= '0;
          rc_rem[i]    <= '0;
        end
      end

      if (win_valid)
        rr_ptr <= win_bank + 1'b1;

      // Push
      if (q_push) begin
        q_valid[free_slot] <= 1'b1;
        q_addr[free_slot]  <= req_addr;
        q_wdata[free_slot] <= req_wdata;
        q_write[free_slot] <= req_write;
        q_tag[free_slot]   <= tag_alloc;
        tag_alloc          <= tag_alloc + 1'b1;
      end

      // Dispatch
      if (disp_valid) begin
        q_valid[disp_slot] <= 1'b0;
        b_addr[disp_bank]  <= q_addr[disp_slot];
        b_wdata[disp_bank] <= q_wdata[disp_slot];
        b_write[disp_bank] <= q_write[disp_slot];
        b_tag[disp_bank]   <= q_tag[disp_slot];
        b_need_act[disp_bank] <= 1'b0;
        if (bank_open[disp_bank] &&
            (bank_row[disp_bank] == addr_row(q_addr[disp_slot])))
          b_state[disp_bank] <= q_write[disp_slot] ? ST_WR : ST_RD;
        else if (bank_open[disp_bank]) begin
          b_need_act[disp_bank] <= 1'b1;
          b_state[disp_bank]    <= ST_PRE;
        end else
          b_state[disp_bank] <= ST_ACT;
      end

      // Count update
      unique case ({q_push, disp_valid})
        2'b10: q_count <= q_count + 1'b1;
        2'b01: q_count <= q_count - 1'b1;
        2'b11: q_count <= q_count;
        default: ;
      endcase

      // Timers
      for (int i = 0; i < NUM_BANKS; i++) begin
        if (ras_rem[i] != 0) ras_rem[i] <= ras_rem[i] - 1'b1;
        if (rc_rem[i]  != 0) rc_rem[i]  <= rc_rem[i]  - 1'b1;
        if (b_timer[i] != 0) b_timer[i] <= b_timer[i] - 8'd1;
      end

      // Issue side-effects
      if (win_valid) begin
        case (win_cmd)
          CMD_PRE: begin
            bank_open[win_bank] <= 1'b0;
            b_timer[win_bank]   <= 8'(tRP > 0 ? tRP - 1 : 0);
            b_state[win_bank]   <= ST_PRE_WAIT;
          end
          CMD_ACT: begin
            bank_open[win_bank] <= 1'b1;
            bank_row[win_bank]  <= addr_row(b_addr[win_bank]);
            ras_rem[win_bank]   <= tRAS[$bits(ras_rem[0])-1:0];
            rc_rem[win_bank]    <= tRC[$bits(rc_rem[0])-1:0];
            b_timer[win_bank]   <= 8'(tRCD > 0 ? tRCD - 1 : 0);
            b_state[win_bank]   <= ST_ACT_WAIT;
          end
          CMD_WR: begin
            b_timer[win_bank] <= 8'(tWR > 0 ? tWR - 1 : 0);
            b_state[win_bank] <= ST_WR_WAIT;
          end
          CMD_RD: begin
            rd_inflight       <= 1'b1;
            rd_bank_q         <= win_bank;
            b_state[win_bank] <= ST_RD_WAIT;
          end
          default: ;
        endcase
      end

      // Wait exits
      for (int i = 0; i < NUM_BANKS; i++) begin
        if (!(win_valid && win_bank == i[$clog2(NUM_BANKS)-1:0] && win_cmd == CMD_PRE)) begin
          if (b_state[i] == ST_PRE_WAIT && b_timer[i] == 0) begin
            if (b_need_act[i]) begin
              b_need_act[i] <= 1'b0;
              b_state[i]    <= ST_ACT;
            end else
              b_state[i] <= ST_IDLE;
          end
        end
        if (!(win_valid && win_bank == i[$clog2(NUM_BANKS)-1:0] && win_cmd == CMD_ACT)) begin
          if (b_state[i] == ST_ACT_WAIT && b_timer[i] == 0)
            b_state[i] <= b_write[i] ? ST_WR : ST_RD;
        end
        if (!(win_valid && win_bank == i[$clog2(NUM_BANKS)-1:0] && win_cmd == CMD_WR)) begin
          if (b_state[i] == ST_WR_WAIT && b_timer[i] == 0) begin
            rsp_done[b_tag[i]] <= 1'b1;
            rsp_data[b_tag[i]] <= '0;
            b_state[i] <= ST_IDLE;
          end
        end
      end

      if (rd_inflight && dram_data_valid) begin
        rsp_done[b_tag[rd_bank_q]] <= 1'b1;
        rsp_data[b_tag[rd_bank_q]] <= dram_rdata;
        b_state[rd_bank_q] <= ST_IDLE;
        rd_inflight <= 1'b0;
      end

      if (rsp_valid && rsp_ready) begin
        rsp_done[tag_retire] <= 1'b0;
        tag_retire <= tag_retire + 1'b1;
      end
    end
  end

  logic unused_page_hit;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) unused_page_hit <= 1'b0;
    else        unused_page_hit <= dram_page_hit;
  end

endmodule
