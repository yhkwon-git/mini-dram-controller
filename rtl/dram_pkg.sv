// Mini-DRAM package — geometry, timing, commands, FSM states (see docs/spec.md).
`timescale 1ns/1ps

package dram_pkg;

  // ---------------------------------------------------------------------------
  // Geometry — matches docs/spec.md address map
  // ---------------------------------------------------------------------------
  localparam int NUM_BANKS      = 4;
  localparam int ROW_BITS       = 8;   // 256 rows / bank
  localparam int COL_BITS       = 4;   // 16 columns / row
  localparam int DATA_BITS      = 32;
  localparam int ADDR_BITS      = $clog2(NUM_BANKS) + ROW_BITS + COL_BITS; // 14
  localparam int QUEUE_DEPTH    = 4;   // host request queue (multi-outstanding)
  localparam int QUEUE_AW       = $clog2(QUEUE_DEPTH);

  // ---------------------------------------------------------------------------
  // Timing (clock cycles) — own model; see docs/spec.md
  // ---------------------------------------------------------------------------
  localparam int tRCD = 3;   // ACT -> RD/WR
  localparam int tRP  = 3;   // PRE -> ACT
  localparam int tRAS = 6;   // ACT -> PRE (min)
  localparam int tRC  = 9;   // ACT -> ACT same bank (≈ tRAS+tRP)
  localparam int tRFC = 12;  // REF busy window
  localparam int tCL  = 2;   // RD -> data_valid
  localparam int tWR  = 2;   // WR recovery before PRE
  localparam int tREFI = 64; // refresh opportunity period

  // ---------------------------------------------------------------------------
  // DRAM command encoding (controller -> model)
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    CMD_NOP  = 3'b000,
    CMD_ACT  = 3'b001,
    CMD_RD   = 3'b010,
    CMD_WR   = 3'b011,
    CMD_PRE  = 3'b100,
    CMD_REF  = 3'b101
  } dram_cmd_e;

  // ---------------------------------------------------------------------------
  // Controller FSM states (skeleton)
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_ACT,
    ST_ACT_WAIT,
    ST_RD,
    ST_RD_WAIT,
    ST_WR,
    ST_WR_WAIT,
    ST_PRE,
    ST_PRE_WAIT,
    ST_REF,
    ST_REF_WAIT,
    ST_ERROR
  } ctrl_state_e;

  // Address helpers
  function automatic logic [$clog2(NUM_BANKS)-1:0] addr_bank(input logic [ADDR_BITS-1:0] a);
    return a[ADDR_BITS-1 -: $clog2(NUM_BANKS)];
  endfunction

  function automatic logic [ROW_BITS-1:0] addr_row(input logic [ADDR_BITS-1:0] a);
    return a[COL_BITS +: ROW_BITS];
  endfunction

  function automatic logic [COL_BITS-1:0] addr_col(input logic [ADDR_BITS-1:0] a);
    return a[COL_BITS-1:0];
  endfunction

endpackage : dram_pkg
