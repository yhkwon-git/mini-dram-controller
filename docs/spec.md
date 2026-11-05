# Mini DRAM Controller Spec / 미니 DRAM 컨트롤러 스펙

**Scope:** `host_if` → `mem_ctrl` (v2: request queue + command-level scheduler) → `dram_model`  
**Source of truth for constants:** `rtl/dram_pkg.sv`  
**Clock:** single sync domain (`clk`, active-low `rst_n`). Timing is in **controller clock cycles**.

v1 (bank engines, one read in flight, drain-then-REF) is described in the git history up to commit `2eabd33`. This file describes v2.

---

## 1. Geometry & address map / 주소 맵

| Symbol | Value | Meaning |
|--------|------:|---------|
| `NUM_BANKS` | 4 | banks |
| `ROW_BITS` | 8 | 256 rows / bank |
| `COL_BITS` | 4 | 16 columns / row |
| `DATA_BITS` | 32 | one RD/WR moves one 32-bit burst: one cycle on the data bus |
| `ADDR_BITS` | 14 | `BANK_BITS + ROW_BITS + COL_BITS` |
| `QUEUE_DEPTH` | 8 | request queue entries (`mem_ctrl` parameter `DEPTH`) |
| `TAG_BITS` | 4 | response tags: at most 15 requests in flight |

**Packed host address** `[ADDR_BITS-1:0]` (MSB→LSB):

```
[ bank | row | col ] = [13:12 | 11:4 | 3:0]
```

Helpers in `dram_pkg`: `addr_bank`, `addr_row`, `addr_col`.

---

## 2. Timing parameters / 타이밍 파라미터

Own scaled model, not JEDEC values. A gap counts the clock edges between the two edges that sample the events; the model and the checker use the same convention.

| Param | Cycles | Rule |
|------:|-------:|------|
| `tRCD` | 3 | ACT → RD/WR, same bank |
| `tRP` | 3 | PRE/PREA → ACT or REF, same bank |
| `tRAS` | 6 | ACT → PRE, same bank |
| `tRC` | 9 | ACT → ACT, same bank |
| `tRTP` | 2 | RD → PRE, same bank |
| `tWR` | 2 | write recovery: WR → PRE ≥ `WL + 1 + tWR` = 4 |
| `tCCD` | 1 | RD/WR → RD/WR, any bank (one burst per cycle) |
| `tRRD` | 2 | ACT → ACT, different banks |
| `tFAW` | 8 | at most four ACTs in any 8-cycle window |
| `tWTR` | 4 | WR → RD, any bank |
| `tRTW` | 4 | RD → WR, any bank (data bus turnaround) |
| `tCL` | 2 | RD → the edge where the model registers `data_valid` |
| `RL` | 3 | RD → the edge that samples `data_valid` (`tCL + 1`) |
| `WL` | 1 | WR → the edge that samples `wdata_en` and `wdata` |
| `tRFC` | 12 | REF → next command |
| `tREFI` | 64 | one REF is owed every `tREFI` cycles |
| `REF_POSTPONE_MAX` | 8 | REFs that may be owed before data is at risk (checker limit) |

With these values a RD's data (edge `t + 3`) and a WR's data (edge `t + 1`) never meet on the data bus: `tRTW` keeps a WR's data after the previous RD's data, and `tWTR` keeps a RD after the previous write's data.

---

## 3. Command set / 명령 (`dram_cmd_e`)

| Cmd | Code | Effect on `dram_model` |
|-----|------|-------------------------|
| `CMD_NOP` | `000` | idle |
| `CMD_ACT` | `001` | open `row` on `bank` (error if the bank is open) |
| `CMD_RD` | `010` | read `(bank,row,col)`; data on the bus `RL` edges later |
| `CMD_WR` | `011` | write `(bank,row,col)`; the data comes `WL` edges later with `wdata_en` |
| `CMD_PRE` | `100` | close `bank` |
| `CMD_REF` | `101` | refresh all banks; error if a bank is open; no command for `tRFC` |
| `CMD_PREA` | `110` | close every open bank |

At most one command per cycle.

---

## 4. DRAM-side interface / DRAM 쪽 인터페이스

DFI-like: commands with fixed data latencies and no busy signal. The controller keeps every timing rule itself.

| Signal | Dir (ctrl) | Meaning |
|--------|-----------|---------|
| `dram_cmd`, `dram_bank`, `dram_row`, `dram_col` | out | the command of this cycle |
| `dram_wdata_en`, `dram_wdata` | out | write data, `WL` edges after its WR |
| `dram_data_valid`, `dram_rdata` | in | read data, `RL` edges after its RD, in RD order |

`dram_model` also drives `busy` (the `tRFC` window), `page_hit` and `access_err` for the testbench; the controller does not read them.

---

## 5. Host interface / 호스트 IF (`host_if`)

Simple valid/ready (`host_if` is a combinational pass-through).

**Request** (host → ctrl): `req_valid` / `req_ready`, `req_write` (1=WR, 0=RD), `req_addr[13:0]`, `req_wdata[31:0]`  
**Response** (ctrl → host): `rsp_valid` / `rsp_ready`, `rsp_rdata[31:0]`, `rsp_err`

| Rule | Detail |
|------|--------|
| Accept | `req_ready` = a free queue entry && a free response tag (≤ 15 in flight). Refresh does not block acceptance; queued requests wait |
| Order | Responses return in request order (`tag_retire`). Requests finish out of order across banks; finished data waits in the 16-entry response buffer |
| Complete | RD: when its data arrives (`RL`). WR: when its data goes out (`WL`), with `rsp_rdata = 0` |
| Backpressure | While `rsp_ready = 0`, finished responses wait in the buffer; new requests stop once 15 are in flight |
| `rsp_err` | Reserved; v2 drives 0 |

---

## 6. Scheduler / 스케줄러 (`mc_sched`)

A request stays in `mc_queue` until its RD/WR issues. Every cycle the scheduler looks at all queued requests:

| Step | Rule |
|------|------|
| Next command | hit (its row is open) → RD/WR; miss (bank closed) → ACT; conflict (another row open) → PRE |
| Ready | the next command meets every rule: bank (`mc_bank`: tRCD, tRP, tRAS, tRC, tRTP, write recovery), channel (`mc_chan`: tCCD, tRRD, tFAW, tWTR, tRTW, tRFC), and for a RD a free read-return slot (`RD_PIPE`) |
| Same address | a RD/WR waits until every older request to the same address has issued its own (`q_dep`, written at accept, cleared when the older RD/WR issues) |
| Row protection | FR-FCFS: no PRE while any queued request hits the open row. FCFS: no PRE while an older request hits it |
| Pick (FR-FCFS) | the oldest ready RD/WR; if none, the oldest ready ACT/PRE |
| Pick (FCFS) | the oldest ready command of any kind |
| Starvation | when the oldest request has waited `STARVE_LIMIT` cycles, selection is oldest-first and, if it needs a PRE, its bank stops serving younger hits |
| Refresh hold | no ACT and no RD/WR: PREA once every open bank may precharge, then REF once every bank has met tRP and tRC |

**Age:** `mc_queue` keeps an age matrix, `q_older[j][i] = 1` when entry j was accepted before entry i, written at each push. The oldest member of any set of entries is the one no other member is older than: one AND-OR level per entry, no compare chain. (The first v2 cut compared `tag − tag_retire` in a loop; that chain held the clock to 151 MHz on Nangate45. The matrix gives 357 MHz with the same decisions; see the README PPA section.)

**Data:** each RD pushes its tag into a 4-entry read-return FIFO; each `data_valid` pops one. Each WR's tag and data go through a `WL`-stage pipeline that drives `wdata_en`.

---

## 7. Refresh policy / 리프레시 (`mc_refresh`)

| Item | Policy |
|------|--------|
| Owed | a free-running counter adds one owed REF every `tREFI` cycles, whatever the traffic does; each REF pays one back. The average REF interval is `tREFI` by construction |
| When | when one is owed and the queue is empty, or at once when `REF_URGENT` (4) are owed |
| Sequence | `hold` goes high and stays high until the REF issues: no ACT, no RD/WR; PREA once every open bank meets tRAS, tRTP and write recovery; REF once every bank meets tRP |
| After | the controller blocks every command for `tRFC` itself (`mc_chan`) |

With `REF_URGENT = 4` at most 4 REFs are owed (checker limit 8). Measured REF interval: 63.6–63.8 cycles on every random pattern (v1: 88–135).

---

## 8. `mem_ctrl` parameters / 파라미터

| Parameter | Default | Meaning |
|-----------|--------:|---------|
| `DEPTH` | 8 | request queue entries |
| `FR_FCFS` | 1 | 1 = FR-FCFS, 0 = FCFS |
| `RD_PIPE` | 4 | RDs on the DRAM bus at once (v1 behaved like 1) |
| `STARVE_LIMIT` | 160 | cycles before the oldest request overrides row hits (≤ 255) |
| `REF_URGENT` | 4 | owed REFs that stop new traffic |

`mem_ctrl_top` and `tb_mem_ctrl_rand` pass them through; the regression builds four variants (`make regress`).

---

## 9. Block roles / 블록

| Module | Role |
|--------|------|
| `host_if` | Host↔ctrl valid/ready (combinational pass-through) |
| `mem_ctrl` | Wires the blocks below; owns accept (`req_ready`) |
| `mc_queue` | Request entries, age matrix, same-address dependencies, wait counters |
| `mc_bank` ×4 | Open row and same-bank timing counters |
| `mc_chan` | Channel timing counters, tFAW window, tRFC blackout |
| `mc_refresh` | Owed REFs and the refresh hold |
| `mc_sched` | Next command per request, readiness, FR-FCFS/FCFS pick, PREA/REF |
| `mc_resp` | Tags, read-return FIFO, write-data pipeline, in-order response buffer |
| `dram_model` | Banks, open rows, memory array, read/write data pipelines, `access_err` |
| `mem_ctrl_top` | Instantiates `host_if`, `mem_ctrl`, `dram_model` |

---

## 10. Implementation status / 구현 상태

| Item | Status |
|------|--------|
| v2 controller, parameters above | done |
| Timing and protocol checker, host SVA (bind) | `tb/dram_timing_checker.sv`, `tb/host_if_checker.sv` |
| Directed TB (5 scenarios) and random TB (6 patterns, 22 bins, 4 build variants) | `tb/` |
| Area and timing flow | `make ppa` (`syn/ppa.sh`) |
| Negative tests that drive `dram_model` directly | TODO |
| Read/write queues with write drain, page policies, address maps | TODO (next step) |
| Separate row and column command buses, bank groups, per-bank refresh | TODO |
