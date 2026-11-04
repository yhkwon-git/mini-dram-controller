# Verification coverage note / 커버리지 노트

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

Scenario 5 fails on the pre-fix RTL (commit `6049e5a`): the 17th read reuses the tag of the first, still-buffered read, so the first response returns the 17th read's data (`0x50000010` instead of `0x50000000`).

Scenario 4 used to check "≥ 2 banks open". With an open-page policy banks stay open after a serial schedule too (and two were already open before the burst), so it now counts bank engines that are busy at the same time.

## Cheap checks in TB / RTL

- TB tallies `dram_access_err` pulses, `rsp_err` pulses and `CMD_REF` commands
- A failed check prints `[TB] ERROR ...` and the run continues; the end prints `[TB] FAIL — n error(s)` through `$fatal`, so `make sim` exits non-zero on any simulator
- In-order host responses via tag scoreboard (`tag_retire`), at most 15 requests in flight
- Single outstanding DRAM RD (`rd_inflight`) — model has one CAS data pipe

## Gaps (not yet automated)

| Gap | Notes |
|-----|--------|
| Out-of-order dispatch | Scenario 5 fills all 4 queue slots (reads wait behind the single read pipe while `rsp_ready` is low), but no dispatch in the TB ever passes an older entry, so bank-level reordering is not exercised. Scenarios 1–4 keep occupancy ≤ 1 (blocking host tasks) |
| Write-hit path | Dispatch straight to `ST_WR` on an open row never happens in the TB |
| Model error paths | `access_err` never fires — no negative tests (missing PRE, wrong row) |
| Timing assertions | `dram_model` does not check command spacing (tRCD / tRP / tRAS / tRC / tWR); add SVA or a bind checker |
| REF under heavy load | No test forces `ref_due` while all four banks are busy |
| Random traffic / coverage bins | Hit/miss/PRE/ACT/REF cross |
| cocotb path | `test_mem_ctrl.py` is a reset/idle smoke test |

## How to extend

1. Non-blocking host driver (several requests before the first response) with mixed banks, to reach out-of-order dispatch and the write-hit path.
2. Negative tests that drive `dram_model` directly (ACT on an open bank, RD on a closed bank) and expect `access_err`.
3. Per-bank command-spacing SVA; `make sim WAVES=1` writes `tb_mem_ctrl.vcd` for waveform checks.
