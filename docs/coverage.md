# Verification coverage note / 커버리지 노트

The full verification plan, checker rules and regression results are in
[verification.md](verification.md). This note tracks what each test covers and
what is still open. Numbers are from commit `2eabd33`.

## Covered by `make sim` (`tb/tb_mem_ctrl.sv`)

| # | Scenario | Checks |
|---|----------|--------|
| 1 | Page hit WR→RD | Read-back data (the hit path itself is not asserted) |
| 2 | Page miss (same bank, new row) | PRE→ACT path; old + new row data |
| 3 | Multi-bank + row conflict | Bank1 data survives bank0 row change |
| 4 | 4-bank write burst | ≥ 2 bank engines busy in the same cycle (observed 4); read-back of all 4 words |
| 5 | Response back-pressure | `rsp_ready` low for 150 cycles while 20 reads are issued (more than the 16 tags): 20/20 responses, in order, correct data; ≥ 1 REF during the scenario |
| — | Model `access_err` | Must stay 0 under the controller's schedule |
| — | `rsp_err` | Counted on every accepted response; must stay 0 |
| — | Bound checkers | DRAM timing and protocol rules, host valid/ready SVA (below); any violation fails the run |

Scenario 5 fails on the pre-fix RTL (commit `6049e5a`): the 17th read reuses the tag of the first, still-buffered read, so the first response returns the 17th read's data (`0x50000010` instead of `0x50000000`).

Scenario 4 used to check "≥ 2 banks open". With an open-page policy banks stay open after a serial schedule too (and two were already open before the burst), so it now counts bank engines that are busy at the same time.

## Covered by `make regress` (`tb/tb_mem_ctrl_rand.sv`)

Six traffic patterns × 50 seeds × 5,000 requests: 300/300 PASS, no data
mismatch, no timing or protocol violation, 17/17 functional bins. The
scoreboard predicts every response from a reference memory when the request
is accepted; a DRAM pin monitor matches each RD/WR to its request.

## Checkers bound into every build (`tb/mc_bind.sv`)

- `dram_timing_checker`: tRCD, tRP (PRE→ACT and PRE→REF), tRAS, tRC, tWR, tRFC, exact tCL return; ACT to an open bank, RD/WR to a closed bank or another row, data with no RD, a RD whose data never came. It reads only the DRAM pins, not `mem_ctrl`.
- Known refresh gaps, counted as waived: REF while a row is open (no PREA), refresh debt above 8 tREFI.
- `host_if_checker`: request and response hold until taken, no X/Z on the handshake, no `rsp_err`; five cover points on handshake corners.
- Both checkers fail the run when the build has assertions off (`--assert` missing).

## Code coverage (`make cov`)

| Module | Line | Branch | Toggle |
|--------|-----:|-------:|-------:|
| `mem_ctrl`, directed only | 94.1% | 91.7% | 61.8% |
| `mem_ctrl`, directed + random | 97.1% | 94.4% | 95.9% |
| RTL total, directed + random | 97.9% | 92.2% | 97.1% |

## Closed by the random regression

| Former gap | Now |
|------------|-----|
| Out-of-order dispatch | 332,014 cross-bank reorders seen on the DRAM pins; responses stayed in order |
| Write-hit path | 212,161 write hits |
| Timing assertions | `dram_timing_checker`, bound into both testbenches |
| Random traffic / coverage bins | 17 bins: hit/miss/conflict × RD/WR, in-flight depth, all banks busy, RAW/WAW, tag-limit stall, long response stall, REF with responses owed, REF under back-pressure, reorder |

## Still open

| Gap | Notes |
|-----|--------|
| Model error paths | `access_err` never fires — no negative tests (missing PRE, wrong row). `dram_model.sv:93/110/133` stay unreached |
| `mem_ctrl.sv:318` | PRE_WAIT → IDLE without ACT is dead under the v1 open-page policy; a close-page policy would use it |
| Refresh | REF without PREA and late REFs (peak debt 549 under `stride`) are waived until the refresh fix |
| REF while all four banks are busy | Likely hit by the random runs but not measured by a bin |
| Timing rules not in the spec yet | tCCD, tRRD, tFAW, tWTR join the checker when they join `dram_pkg` |
| cocotb path | `test_mem_ctrl.py` is a reset/idle smoke test |
