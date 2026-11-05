// Mini-DRAM package: geometry, bank groups, timing, commands, policies, address maps (docs/spec.md).
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

  // Bank groups: the bank number's MSB. Two commands in one group need the
  // longer (_L) spacing, in different groups the shorter (_S) one.
  localparam int BG_BITS = 1;
  localparam int NUM_BG  = 1 << BG_BITS;   // 2 groups x 2 banks

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
  // Bank groups: _S across groups, _L within one group
  localparam int tCCD_S = 1;  // RD/WR -> RD/WR (one burst per cycle)
  localparam int tCCD_L = 2;
  localparam int tRRD_S = 2;  // ACT -> ACT, different banks; a REFpb counts as an ACT here
  localparam int tRRD_L = 3;
  localparam int tWTR_S = 2;  // WR -> RD
  localparam int tWTR_L = 4;
  // Any bank
  localparam int tFAW = 8;    // at most four ACTs in any tFAW window
  localparam int tRTW = 4;    // RD -> WR (data bus turnaround)
  // Data
  localparam int tCL  = 2;        // RD -> the edge where the model registers data_valid
  localparam int RL   = tCL + 1;  // RD -> the edge that samples data_valid
  localparam int WL   = 1;        // WR -> the edge that samples wdata_en and wdata
  // Refresh
  localparam int tRFC  = 12;  // REF -> next command
  localparam int tREFI = 64;  // every bank needs one refresh per tREFI
  localparam int REF_POSTPONE_MAX = 8;  // refreshes a bank may be owed before data is at risk
  localparam int tRFCpb  = 8;                  // REFpb -> next ACT to that bank
  localparam int tREFIpb = tREFI / NUM_BANKS;  // per-bank mode: one REFpb owed per tREFIpb, banks in turn
  // RowHammer: refresh management (RFM). Each bank counts its ACTs (RAA); a
  // refresh of the bank (REF or REFpb) takes RAA_IMT off the count. At RAA_IMT
  // the controller may give an idle bank an extra REFpb; at RAA_MMT the bank
  // takes no ACT until it has had one. Scaled like the rest: a real device fits
  // about twice RAAIMT ACTs into a tREFI, and seven fit here (tRC 9).
  localparam int RAA_IMT = 4;
  localparam int RAA_MMT = 12;

  // ---------------------------------------------------------------------------
  // DRAM commands (controller -> model). The row bus carries ACT, PRE, PREA,
  // REF and REFPB; the column bus carries RD and WR.
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    CMD_NOP   = 3'b000,
    CMD_ACT   = 3'b001,
    CMD_RD    = 3'b010,
    CMD_WR    = 3'b011,
    CMD_PRE   = 3'b100,
    CMD_REF   = 3'b101,  // all banks; every bank must be precharged
    CMD_PREA  = 3'b110,  // precharge all open banks
    CMD_REFPB = 3'b111   // refresh one bank; that bank must be precharged
  } dram_cmd_e;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [BG_BITS-1:0] bg_of(input logic [BANK_BITS-1:0] b);
    return b[BANK_BITS-1 -: BG_BITS];  // the group is the bank number's MSB
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------------------
  // Refresh mode (mem_ctrl parameter REF_MODE)
  // ---------------------------------------------------------------------------
  localparam int REF_ALL  = 0;  // REF: PREA, then all banks for tRFC
  localparam int REF_BANK = 1;  // REFpb: one bank at a time for tRFCpb; the others keep working

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
