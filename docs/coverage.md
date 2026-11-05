# Verification coverage note / 커버리지 노트

The full verification plan, checker rules and regression results are in
[verification.md](verification.md). This note tracks what each test covers and
what is still open. Numbers are from commit `c1b8248` (controller v2).

## Covered by `make sim` (`tb/tb_mem_ctrl.sv`)

| # | Scenario | Checks |
|---|----------|--------|
| 1 | Page hit WR→RD | Read-back data |
| 2 | Page miss (same bank, new row) | PRE→ACT path; old + new row data |
| 3 | Multi-bank + row conflict | Bank1 data survives bank0 row change |
| 4 | 4-bank write burst | ≥ 2 banks opening at once on the DRAM pins (ACT out, WR not yet); read-back of all 4 words |
| 5 | Response back-pressure | `rsp_ready` low for 150 cycles while 20 reads are issued (more than the 16 tags): 20/20 responses, in order, correct data; ≥ 1 REF during the scenario |
| — | Model `access_err` | Must stay 0 under the controller's schedule |
| — | `rsp_err` | Counted on every accepted response; must stay 0 |
| — | Bound checkers | 14 timing rules, 9 protocol rules, host valid/ready SVA; any violation fails the run |

Scenario 5 fails on the pre-fix v1 RTL (commit `6049e5a`): the 17th read reuses the tag of the first, still-buffered read, so the first response returns the 17th read's data (`0x50000010` instead of `0x50000000`). v2 keeps the same 15-in-flight rule.

## Covered by `make regress` (`tb/tb_mem_ctrl_rand.sv`)

Six traffic patterns. Default build 50 seeds, four parameter variants
(FCFS, starvation limit 24, one RD in flight, depth 4) 10 seeds each,
5,000 requests per run: 540/540 PASS, no data mismatch, no timing or
protocol violation, 22/22 functional bins. The scoreboard predicts every
response from a reference memory when the request is accepted; a DRAM pin
monitor matches each RD/WR to its request.

## Checkers bound into every build (`tb/mc_bind.sv`)

- `dram_timing_checker`: tRCD, tRP, tRAS, tRC, tRTP, tWR, tRRD, tFAW, tCCD, tWTR, tRTW, tRFC, exact RL and WL; ACT to an open bank, RD/WR to a closed bank or another row, read or write data with no command, a command whose data never came, REF with a row open, more than 8 REFs owed. It reads only the DRAM pins, not `mem_ctrl`. No waivers in v2.
- `host_if_checker`: request and response hold until taken, no X/Z on the handshake, no `rsp_err`; five cover points on handshake corners.
- Both checkers fail the run when the build has assertions off (`--assert` missing).

## Code coverage (`make cov`)

| Scope | Line | Branch | Toggle |
|-------|-----:|-------:|-------:|
| controller (`mem_ctrl` + `mc_*`), directed only | 97.6% | 96.6% | 52.9% |
| controller, directed + random (all builds) | 97.6% | 98.9% | 95.6% |
| RTL total, directed + random | 96.7% | 93.5% | 96.1% |

## Closed

| Former gap | Now |
|------------|-----|
| Out-of-order dispatch | 912,402 cross-request reorders seen on the DRAM pins; responses stayed in order |
| Write-hit path | 464,503 write hits |
| Timing assertions | `dram_timing_checker`, bound into both testbenches |
| Random traffic / coverage bins | 22 bins (see verification.md) |
| Late REFs, REF without PREA (v1) | v2 pays one REF per tREFI and precharges first; both rules are violations again, and none fire |
| Starvation guard, FCFS path | Reached only by the `starve24` and `fcfs` builds, which `make regress` and `make cov` now run |

## Still open

| Gap | Notes |
|-----|--------|
| Model error paths | `access_err` never fires — no negative tests (ACT on an open bank, RD on a closed bank, a command inside tRFC, stray write data). Those `dram_model` branches stay unreached |
| `mc_refresh.sv:43` | Saturation of the owed-REF counter at 15; unreachable while `REF_URGENT` is 4 |
| `mc_resp.sv:92` | Write-pipe stage used only when WL > 1 |
| REF while all four banks are busy | Likely hit by the random runs but not measured by a bin |
| cocotb path | `test_mem_ctrl.py` is a reset/idle smoke test |
