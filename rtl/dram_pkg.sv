// Mini-DRAM package: geometry, timing, commands, page policies, address maps (docs/spec.md).
`timescale 1ns/1ps

package dram_pkg;

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam int NUM_BANKS   = 4;
  localparam int BANK_BITS   = $clog2(NUM_BANKS);
  localparam int ROW_BITS    = 8;    // 256 rows per bank
  localparam int COL_BITS    = 4;    // 16 columns per row
  localparam int DATA_BITS   = 32;   // one RD/WR moves one 32-bit burst, one cycle on the data bus
  localparam int ADDR_BITS   = BANK_BITS + ROW_BITS + COL_BITS;  // 14
  localparam int QUEUE_DEPTH = 8;    // entries per queue: 8 reads + 8 writes (mem_ctrl DEPTH)
  localparam int TAG_BITS    = 4;    // response tags: at most 15 requests in flight

  // ---------------------------------------------------------------------------
  // Timing in controller cycles. Own scaled model, not JEDEC values.
  // A gap counts the clock edges between the two edges that sample the events.
  // ---------------------------------------------------------------------------
  // Same bank
  localparam int tRCD = 3;   // ACT -> RD/WR
  localparam int tRP  = 3;   // PRE/PREA -> ACT or REF
  localparam int tRAS = 6;   // ACT -> PRE
  localparam int tRC  = 9;   // ACT -> ACT
  localparam int tRTP = 2;   // RD -> PRE
  localparam int tWR  = 2;   // write recovery: WR -> PRE >= WL + 1 + tWR
  // Any bank
  localparam int tCCD = 1;   // RD/WR -> RD/WR (one burst per cycle)
  localparam int tRRD = 2;   // ACT -> ACT, different banks
  localparam int tFAW = 8;   // at most four ACTs in any tFAW window
  localparam int tWTR = 4;   // WR -> RD
  localparam int tRTW = 4;   // RD -> WR (data bus turnaround)
  // Data
  localparam int tCL  = 2;        // RD -> the edge where the model registers data_valid
  localparam int RL   = tCL + 1;  // RD -> the edge that samples data_valid
  localparam int WL   = 1;        // WR -> the edge that samples wdata_en and wdata
  // Refresh
  localparam int tRFC  = 12;  // REF -> next command
  localparam int tREFI = 64;  // one REF is owed every tREFI cycles
  localparam int REF_POSTPONE_MAX = 8;  // REFs that may be owed before data is at risk

  // ---------------------------------------------------------------------------
  // DRAM commands (controller -> model)
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    CMD_NOP  = 3'b000,
    CMD_ACT  = 3'b001,
    CMD_RD   = 3'b010,
    CMD_WR   = 3'b011,
    CMD_PRE  = 3'b100,
    CMD_REF  = 3'b101,  // all banks; every bank must be precharged
    CMD_PREA = 3'b110   // precharge all open banks
  } dram_cmd_e;

  // ---------------------------------------------------------------------------
  // Page policy (mem_ctrl parameter PAGE_POLICY)
  // ---------------------------------------------------------------------------
  localparam int PAGE_OPEN  = 0;  // a row stays open until a conflict or refresh closes it
  localparam int PAGE_CLOSE = 1;  // RD/WR with auto-precharge unless a queued request hits the row
  localparam int PAGE_TIMER = 2;  // open, and PRE a row nobody wants after PAGE_TIMEOUT idle cycles

  // ---------------------------------------------------------------------------
  // Address maps (mem_ctrl parameter ADDR_MAP). The host address is a word
  // address; every map is a bijection onto (bank, row, col), MSB first.
  // ---------------------------------------------------------------------------
  localparam int MAP_BRC = 0;  // [bank | row | col]  a quarter of the space per bank (v1, v2)
  localparam int MAP_RBC = 1;  // [row | bank | col]  one row of columns, then the next bank
  localparam int MAP_RCB = 2;  // [row | col | bank]  consecutive words rotate through the banks
  localparam int MAP_XOR = 3;  // [row | bank | col], bank XOR the low row bits (v3 default)

  // Each map reads different bits of a; lint sees one map per build.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [BANK_BITS-1:0] map_bank(input logic [ADDR_BITS-1:0] a, input int map);
    case (map)
      MAP_RBC: return a[COL_BITS +: BANK_BITS];
      MAP_RCB: return a[BANK_BITS-1:0];
      MAP_XOR: return a[COL_BITS +: BANK_BITS] ^ a[COL_BITS + BANK_BITS +: BANK_BITS];
      default: return a[ADDR_BITS-1 -: BANK_BITS];
    endcase
  endfunction

  function automatic logic [ROW_BITS-1:0] map_row(input logic [ADDR_BITS-1:0] a, input int map);
    case (map)
      MAP_RBC, MAP_RCB, MAP_XOR: return a[ADDR_BITS-1 -: ROW_BITS];
      default:                   return a[COL_BITS +: ROW_BITS];
    endcase
  endfunction

  function automatic logic [COL_BITS-1:0] map_col(input logic [ADDR_BITS-1:0] a, input int map);
    case (map)
      MAP_RCB: return a[BANK_BITS +: COL_BITS];
      default: return a[COL_BITS-1:0];
    endcase
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

endpackage : dram_pkg
