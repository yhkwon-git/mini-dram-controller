# Verification coverage note / 커버리지 노트

The full verification plan, checker rules and regression results are in
[verification.md](verification.md). This note tracks what each test covers and
what is still open. Numbers are from commit `ab9d522` (controller v4).

## Covered by `make sim` (`tb/tb_mem_ctrl.sv`)

| # | Scenario | Checks |
|---|----------|--------|
| 1 | Page hit WR→RD | Read-back data, after the write has reached the DRAM |
| 2 | Page miss (same bank, new row) | PRE→ACT path; old + new row data |
| 3 | Multi-bank + row conflict | Bank1 data survives bank0 row change |
| 4 | 4-bank write burst | ≥ 2 banks opening at once on the DRAM pins (ACT out, WR not yet); read-back of all 4 words |
| 5 | Response back-pressure | `rsp_ready` low for 150 cycles while 20 reads are issued (more than the 16 tags): 20/20 responses, in order, correct data; ≥ 1 refresh during the scenario |
| 6 | Forwarding | Two writes to one address, then a read before they reach the DRAM: the younger write's data and no RD on the DRAM pins. It starts right after a refresh of that bank (REF, or REFpb to bank 2), so no ACT can issue (tRFC / tRFCpb) and the timing is fixed |
| — | Model `access_err` | Must stay 0 under the controller's schedule |
| — | `rsp_err` | Counted on every accepted response; must stay 0 |
| — | Bound checkers | 18 timing rules, 10 protocol rules, host valid/ready SVA; any violation fails the run |

The scenarios name banks and rows; the TB builds each address with the inverse of the default map (`MAP_XOR`) and stops if the build uses another one. It follows both command buses: ACTs on the row bus, RD/WR on the column bus.

Scenario 5 fails on the pre-fix v1 RTL (commit `6049e5a`): the 17th read reuses the tag of the first, still-buffered read, so the first response returns the 17th read's data (`0x50000010` instead of `0x50000000`). v4 keeps the same 15-in-flight rule.

## Covered by `make regress` (`tb/tb_mem_ctrl_rand.sv`)

Six traffic patterns. Default build 50 seeds, fifteen parameter variants
(one command bus, all-bank refresh, both, RFM only at the limit, FCFS,
starvation limit 24, one RD in flight, 4 + 4 entries, no write batches,
FCFS without write batches, close page, timer page, three other address
maps) 10 seeds each, 5,000 requests per run: 1,200/1,200 PASS, no data
mismatch, no timing or protocol violation, 32/32 functional bins. The
scoreboard predicts every response from a reference memory; a DRAM pin
monitor matches each RD/WR to its request through the testbench's own
address-map functions and the open rows it follows on the row bus, checks
that forwarded reads never reach the DRAM, and that every posted write does.

## Checkers bound into every build (`tb/mc_bind.sv`)

- `dram_timing_checker`: both command buses, the column command of an edge before its row command. tRCD, tRP (from PRE, PREA or the implicit precharge of an auto-precharge RD/WR), tRAS, tRC, tRTP, tWR, tRRD_S/L (a REFpb counts for tRRD_S), tFAW, tCCD_S/L, tWTR_S/L, tRTW, tRFC, tRFCpb, exact RL and WL; ACT to an open bank, RD/WR to a closed bank, read or write data with no command, a command whose data never came, REF with a row open, REFpb to an open bank, more than 8 refreshes owed by any bank, an ACT to a bank whose RAA has reached 12. It reads only the DRAM pins, not `mem_ctrl`. No waivers.
- `host_if_checker`: request and response hold until taken, no X/Z on the handshake, no `rsp_err`; five cover points on handshake corners.
- Both checkers fail the run when the build has assertions off (`--assert` missing).

## Code coverage (`make cov`)

| Scope | Line | Branch | Toggle |
|-------|-----:|-------:|-------:|
| controller (`mem_ctrl` + `mc_*`), directed only | 94.8% | 81.8% | 48.5% |
| controller, directed + random (all builds) | 98.7% | 98.2% | 93.1% |
| RTL total, directed + random | 96.0% | 94.1% | 93.7% |

## Closed

| Former gap | Now |
|------------|-----|
| Out-of-order dispatch | 3,386,363 cross-request reorders seen on the DRAM pins; responses stayed in order |
| Write-hit path | 1,102,895 write hits |
| Timing assertions | `dram_timing_checker`, bound into both testbenches |
| Random traffic / coverage bins | 32 bins (see verification.md) |
| Late REFs, REF without PREA (v1) | v2 and later pay one refresh per bank per tREFI and precharge first; both rules are violations, and none fire |
| Starvation guard, FCFS path | Reached by the `starve24`, `fcfs` and `fcfs_nodrain` builds, which `make regress` and `make cov` run |
| Same-address order with two queues | 151,757 forwarded reads, 143,018 writes behind a queued write, 470,830 writes held behind a queued read; data all correct |
| Page policies, address maps | `close` (211,907 RD/WR with auto-precharge), `timer`, four maps; all PASS |
| Two command buses, bank groups | 1,359,346 edges with a row and a column command; 566,659 column commands back to back in different groups; S/L rules all clean |
| Per-bank refresh, RFM | 1,674,822 REFpb (111,515 with a RD/WR to another bank on the same edge); 131,879 times a bank reached RAA 12, no ACT over the limit |

## Still open

| Gap | Notes |
|-----|--------|
| Model error paths | `access_err` never fires — no negative tests (ACT or REFpb on an open bank, RD on a closed bank, a command inside tRFC or tRFCpb, stray write data). Those `dram_model` branches stay unreached |
| `mc_sched.sv:135–136` | Branches of `older()`: Verilator folds the constant queue index in the unrolled loops, and the counters stay at 0 (the `else` on the same line counts 434,345 in `nodrain` and `fcfs_nodrain`). The cross-queue paths run in those builds |
| `mc_refresh.sv:56` | Saturation of the owed-refresh counter at 15; unreachable while `REF_URGENT` is 4 |
| `mc_resp.sv:100` | Write-pipe stage used only when WL > 1 |
| `mc_chan` toggle (52%) | Every channel counter is 5 bits wide (for tRFC − 1 = 11); the upper bits of the short ones never toggle |
| cocotb path | `test_mem_ctrl.py` is a reset/idle smoke test |
