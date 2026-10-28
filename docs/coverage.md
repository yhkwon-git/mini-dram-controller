# Verification coverage note / 커버리지 노트

## Covered by `make sim` (`tb/tb_mem_ctrl.sv`)

| # | Scenario | Checks |
|---|----------|--------|
| 1 | Page hit WR→RD | Data match; open-row reuse |
| 2 | Page miss (same bank, new row) | PRE→ACT path; old+new row data |
| 3 | Multi-bank + row conflict | Bank1 data survives bank0 row change |
| 4 | Queue burst (4 banks) | Depth-4 accept; **peak `bank_open` ≥ 2** (observed 4); RD back all data |
| — | Model `access_err` | Must stay 0 under legal schedule |
| — | `rsp_err` | Must stay 0 |

## Cheap checks in TB / RTL

- TB tallies `dram_access_err` pulses  
- TB rejects unexpected `rsp_err`  
- In-order host responses via tag scoreboard (`tag_retire`)  
- Single outstanding DRAM RD (`rd_inflight`) — model has one CAS data pipe  

## Gaps (not yet automated)

| Gap | Notes |
|-----|--------|
| REF-under-load | Forced `tREFI` expiry mid-traffic + functional continue |
| Backpressure | `rsp_ready` low for long periods / queue full stall |
| Same-bank queue depth | Several entries to one bank while others idle |
| Random traffic / coverage bins | Hit/miss/PRE/ACT/REF cross |
| Formal / SVA | tRAS/tRP/tRCD properties as bind assertions |
| Wave dump regression | `WAVES=1` artifact in CI |
| cocotb path | `test_mem_ctrl.py` still smoke-level |

## How to extend

1. Add a TB task that waits until `refi` near 0, then issues traffic.  
2. Drive `rsp_ready` low during scenario 4 and drain later (watch for deadlock).  
3. `make sim WAVES=1` and archive a short FST/VCD for the portfolio.
