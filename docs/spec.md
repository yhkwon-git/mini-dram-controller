# Mini DRAM Controller Spec / 미니 DRAM 컨트롤러 스펙

**Scope:** `host_if` → `mem_ctrl` (v4: read and write queues, command-level scheduler, row and column command buses, per-bank refresh, RFM) → `dram_model`  
**Source of truth for constants:** `rtl/dram_pkg.sv`  
**Clock:** single sync domain (`clk`, active-low `rst_n`). Timing is in **controller clock cycles**.

v1 (bank engines, one read in flight, drain-then-REF) is in the git history up to commit `2eabd33`, v2 (one queue, writes answered when their data goes out) up to `4010a10`, v3 (one command bus, all-bank refresh, no bank groups) up to `57ad7df`. This file describes v4.

---

## 1. Geometry & address maps / 주소 맵

| Symbol | Value | Meaning |
|--------|------:|---------|
| `NUM_BANKS` | 4 | banks |
| `ROW_BITS` | 8 | 256 rows / bank |
| `COL_BITS` | 4 | 16 columns / row |
| `DATA_BITS` | 32 | one RD/WR moves one 32-bit burst: one cycle on the data bus |
| `ADDR_BITS` | 14 | `BANK_BITS + ROW_BITS + COL_BITS` |
| `QUEUE_DEPTH` | 8 | entries per queue: 8 reads + 8 writes (`mem_ctrl` parameter `DEPTH`) |
| `TAG_BITS` | 4 | response tags: at most 15 requests in flight |
| `BG_BITS` | 1 | bank groups: the bank number's MSB, 2 groups × 2 banks |

The host address is a word address. `ADDR_MAP` picks how it lands on (bank, row, col); every map is a bijection.

| `ADDR_MAP` | Layout (MSB → LSB) | Effect |
|------------|--------------------|--------|
| `MAP_XOR` (3, default) | `[row \| bank ^ row[1:0] \| col]` | like `MAP_RBC`, and strides of one row across all banks (64 words) still rotate banks |
| `MAP_RBC` (1) | `[row \| bank \| col]` | 16 consecutive words share a row, then the next bank |
| `MAP_RCB` (2) | `[row \| col \| bank]` | consecutive words rotate through the banks |
| `MAP_BRC` (0, v1 and v2) | `[bank \| row \| col]` | each bank owns a quarter of the address space |

Helpers in `dram_pkg`: `map_bank`, `map_row`, `map_col`. The testbench has its own implementation of each map (`tb_loc`, written with arithmetic instead of bit slices).

---

## 2. Timing parameters / 타이밍 파라미터

Own scaled model, not JEDEC values. A gap counts the clock edges between the two edges that sample the events; the model and the checker use the same convention.

| Param | Cycles | Rule |
|------:|-------:|------|
| `tRCD` | 3 | ACT → RD/WR, same bank |
| `tRP` | 3 | PRE/PREA/auto-precharge → ACT or REF, same bank |
| `tRAS` | 6 | ACT → PRE, same bank |
| `tRC` | 9 | ACT → ACT, same bank |
| `tRTP` | 2 | RD → PRE, same bank |
| `tWR` | 2 | write recovery: WR → PRE ≥ `WL + 1 + tWR` = 4 |
| `tCCD_S` / `tCCD_L` | 1 / 2 | RD/WR → RD/WR, other / same bank group (one burst per cycle) |
| `tRRD_S` / `tRRD_L` | 2 / 3 | ACT → ACT, other / same bank group, different banks; a REFpb counts as an ACT for `tRRD_S` |
| `tFAW` | 8 | at most four ACTs in any 8-cycle window |
| `tWTR_S` / `tWTR_L` | 2 / 4 | WR → RD, other / same bank group |
| `tRTW` | 4 | RD → WR, any bank (data bus turnaround) |
| `tCL` | 2 | RD → the edge where the model registers `data_valid` |
| `RL` | 3 | RD → the edge that samples `data_valid` (`tCL + 1`) |
| `WL` | 1 | WR → the edge that samples `wdata_en` and `wdata` |
| `tRFC` | 12 | REF (all banks) → next command |
| `tRFCpb` | 8 | REFpb → next ACT to that bank; the other banks keep working |
| `tREFI` | 64 | every bank needs one refresh per `tREFI` |
| `tREFIpb` | 16 | per-bank mode: one REFpb owed every `tREFI / 4`, banks in turn |
| `REF_POSTPONE_MAX` | 8 | refreshes a bank may be owed before data is at risk (checker limit) |
| `RAA_IMT` / `RAA_MMT` | 4 / 12 | refresh management (RowHammer): ACT count at which an RFM is due / at which the bank takes no ACT |

With these values a RD's data (edge `t + 3`) and a WR's data (edge `t + 1`) never meet on the data bus: `tRTW` keeps a WR's data after the previous RD's data, and `tWTR` keeps a RD after the previous write's data.

**Refresh management (RFM):** each bank counts its ACTs (RAA, +1 per ACT); every refresh of the bank (REF or REFpb) takes `RAA_IMT` off, never below 0. An ACT to a bank whose RAA has reached `RAA_MMT` is illegal; the controller gives such a bank a REFpb first. The scale follows the rest of the model: at most seven ACTs per bank fit in one `tREFI` (tRC 9), about twice `RAA_IMT`, as in a real device.

**Auto-precharge:** a RD/WR with `ap = 1` closes its bank. The device precharges on the first edge a PRE would be legal (tRAS from the ACT, tRTP after a RD, write recovery after a WR); the next ACT or REF to that bank must be `tRP` after that edge.

---

## 3. Command set / 명령 (`dram_cmd_e`)

| Cmd | Code | Effect on `dram_model` |
|-----|------|-------------------------|
| `CMD_NOP` | `000` | idle |
| `CMD_ACT` | `001` | open `row` on `bank` (error if the bank is open) |
| `CMD_RD` | `010` | read `(bank,row,col)`; data on the bus `RL` edges later. With `ap`, the bank closes |
| `CMD_WR` | `011` | write `(bank,row,col)`; the data comes `WL` edges later with `wdata_en`. With `ap`, the bank closes |
| `CMD_PRE` | `100` | close `bank` |
| `CMD_REF` | `101` | refresh all banks; error if a bank is open; no command for `tRFC` |
| `CMD_PREA` | `110` | close every open bank |
| `CMD_REFPB` | `111` | refresh one bank; error if it is open; no command to it for `tRFCpb` |

Two command buses, both sampled on every edge: the row bus carries ACT, PRE, PREA, REF and REFPB; the column bus carries RD and WR. The column bus has no row: the device uses the bank's open row.

---

## 4. DRAM-side interface / DRAM 쪽 인터페이스

DFI-like: commands with fixed data latencies and no busy signal. The controller keeps every timing rule itself.

| Signal | Dir (ctrl) | Meaning |
|--------|-----------|---------|
| `dram_rcmd`, `dram_rbank`, `dram_row` | out | the row command of this cycle |
| `dram_ccmd`, `dram_cbank`, `dram_col` | out | the column command of this cycle |
| `dram_ap` | out | auto-precharge with this RD/WR (`PAGE_CLOSE`) |
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
| Accept | a free response tag (≤ 15 in flight), and: a read needs a free read-queue entry unless it is forwarded; a write needs a free write-queue entry and no queued read to its address. Refresh does not block acceptance |
| Same address | a read whose address is in the write queue is answered from the youngest such write (forwarding) and never reaches the DRAM. A write whose address is in the read queue waits on the port until that read has issued. Two writes to one address reach the DRAM in order (`q_dep`) |
| Order | responses return in request order (`tag_retire`); requests finish out of order, and finished data waits in the 16-entry response buffer |
| Complete | RD: when its data arrives (`RL`), or when it is accepted if forwarded. WR: when it is accepted (posted), with `rsp_rdata = 0` |
| Backpressure | while `rsp_ready = 0`, finished responses wait in the buffer; new requests stop once 15 are in flight |
| `rsp_err` | reserved; v3 drives 0 |

---

## 6. Scheduler / 스케줄러 (`mc_sched`)

A request stays in its queue (`mc_queue`, one for reads and one for writes) until its RD/WR issues. Every cycle the scheduler looks at all queued requests and picks one column command and one row command (`CMD_BUS = 2`), or one command of either kind (`CMD_BUS = 1`, v3):

| Step | Rule |
|------|------|
| Next command | hit (its row is open) → RD/WR; miss (bank closed) → ACT; conflict (another row open) → PRE |
| Ready | the next command meets every rule: bank (`mc_bank`: tRCD, tRP, tRAS, tRC, tRTP, write recovery, tRFCpb, RAA below `RAA_MMT` for an ACT), channel per bank group (`mc_chan`: tCCD_S/L, tRRD_S/L, tFAW, tWTR_S/L, tRTW, tRFC), and for a RD a free read-return slot (`RD_PIPE`) |
| Eligible queue | `WDRAIN = 1`: the queue `mc_wdrain` selects (§ 6.1). `WDRAIN = 0`: both queues, oldest first across them as in v2 |
| Pick, column bus | the oldest ready RD/WR of the eligible queue, else of the other queue |
| Pick, row bus | 1. a ready refresh command (PREA, REF, or PRE and REFpb of the bank being refreshed) · 2. an RFM command (PRE, REFpb) · 3. the eligible queue's oldest ready ACT/PRE · 4. the other queue's ACT, or PRE of a row nobody hits, on a bank the eligible queue does not need · 5. a timer PRE (`PAGE_TIMER`). No PRE goes to a bank that has a column command ready |
| One bus (`CMD_BUS = 1`) | refresh, then RFM, then the column pick over the row pick (FR-FCFS) or the older of the two (FCFS) |
| Row protection | FR-FCFS: no PRE while any queued request (either queue) hits the open row. FCFS: no PRE while an older one does |
| Same address | a write waits for every older write to its address (`q_dep`); reads need no order among themselves |
| Starvation | when the oldest eligible request has waited `STARVE_LIMIT` cycles, selection is oldest-first and, if it needs a PRE, its bank stops serving younger hits. A write that has waited that long also switches `mc_wdrain` to write mode |
| Refresh hold | `REF_ALL`: no ACT and no RD/WR on any bank; PREA, then REF. `REF_BANK`: the same for the bank being refreshed only, with PRE and REFpb |
| RFM | a bank at `RAA_MMT` takes no ACT; once no queued request hits its row it is closed and gets a REFpb. With `RFM_EARLY`, a closed bank at `RAA_IMT` that no queued request needs also gets one |

**Age:** each queue keeps an age matrix, `q_older[j][i] = 1` when entry j was accepted before entry i, written at each push; `mc_xage` keeps `w_older_r[w][r]` between the two queues. The oldest member of any set of entries is the one no other member is older than: one AND-OR level per entry, no compare chain.

**One-hot pick:** the selected entry stays one-hot from the scheduler to the queue pop and to the tag and write-data selects (AND-OR), so no index is encoded and decoded again.

**Data:** each RD pushes its tag into a 4-entry read-return FIFO; each `data_valid` pops one. Each WR's data goes through a `WL`-stage pipeline that drives `wdata_en`.

### 6.1 Write batches / 쓰기 모아 보내기 (`mc_wdrain`)

| Mode | When |
|------|------|
| read (default) | reads first |
| write | the write queue reaches `WR_HI` (6) until it is down to `WR_LO` (2); or no read is queued; or a write has waited `STARVE_LIMIT` cycles |

The mode sets priority, not a ban: the other queue still gets a slot nothing in the selected queue can use (pick steps 3 and 4). `wmode` is registered and follows the queues one cycle late.

### 6.2 Page policy / 페이지 정책 (`PAGE_POLICY`)

| Policy | Rule |
|--------|------|
| `PAGE_OPEN` (0, default) | a row stays open until a conflict or refresh closes it |
| `PAGE_CLOSE` (1) | a RD/WR carries auto-precharge unless another queued request (either queue) hits the same row |
| `PAGE_TIMER` (2) | open, and when nothing else is ready, PRE an open bank that no queued request needs and that has had no ACT/RD/WR for `PAGE_TIMEOUT` (16) cycles |

---

## 7. Refresh policy / 리프레시 (`mc_refresh`)

| Item | `REF_BANK` (default) | `REF_ALL` (v3) |
|------|------|------|
| Owed | one REFpb every `tREFIpb` = 16 cycles, banks in turn, so each bank gets one per `tREFI` | one REF every `tREFI` cycles |
| When | when one is owed and no queued request needs that bank, or at once when `REF_URGENT` (4) are owed | when one is owed and both queues are empty, or at once when `REF_URGENT` are owed |
| Sequence | that bank only: no ACT, no RD/WR; PRE once it meets tRAS, tRTP and write recovery; REFpb once it meets tRP | every bank: PREA, then REF |
| After | that bank takes no ACT for `tRFCpb` (8) (`mc_bank`); the other banks keep working | every command waits `tRFC` (12) (`mc_chan`) |

The owed counter runs whatever the traffic does, so every bank is refreshed once per `tREFI` on average in both modes. With `REF_URGENT = 4` at most 4 refreshes are owed (checker limit 8 per bank).

---

## 8. `mem_ctrl` parameters / 파라미터

| Parameter | Default | Meaning |
|-----------|--------:|---------|
| `DEPTH` | 8 | entries per queue (reads, writes) |
| `FR_FCFS` | 1 | 1 = FR-FCFS, 0 = FCFS |
| `WDRAIN` | 1 | 1 = read/write modes with watermarks, 0 = reads and writes compete oldest-first (v2) |
| `WR_HI`, `WR_LO` | 6, 2 | write batch start and end (queued writes) |
| `PAGE_POLICY` | `PAGE_OPEN` | `PAGE_OPEN`, `PAGE_CLOSE`, `PAGE_TIMER` |
| `PAGE_TIMEOUT` | 16 | idle cycles before a timer PRE |
| `ADDR_MAP` | `MAP_XOR` | `MAP_XOR`, `MAP_RBC`, `MAP_RCB`, `MAP_BRC` |
| `CMD_BUS` | 2 | 2 = row and column command buses, 1 = one command per cycle (v3) |
| `REF_MODE` | `REF_BANK` | `REF_BANK` = per-bank REFpb, `REF_ALL` = PREA + REF (v3) |
| `RFM_EARLY` | 1 | 1 = RFM at `RAA_IMT` for idle banks too, 0 = only at `RAA_MMT` |
| `RD_PIPE` | 4 | RDs on the DRAM bus at once (v1 behaved like 1) |
| `STARVE_LIMIT` | 160 | cycles before the oldest request overrides row hits (≤ 255) |
| `REF_URGENT` | 4 | owed REFs that stop new traffic |

`mem_ctrl_top` and `tb_mem_ctrl_rand` pass them through; the regression builds fifteen variants (`make regress`).

---

## 9. Block roles / 블록

| Module | Role |
|--------|------|
| `host_if` | Host↔ctrl valid/ready (combinational pass-through) |
| `mem_ctrl` | Wires the blocks below; address map, accept (`req_ready`), forwarding, tag and write-data selects |
| `mc_queue` ×2 | Read queue and write queue: entries, age matrix, same-address match, write order (`q_dep`), wait counters |
| `mc_xage` | Age between the two queues |
| `mc_wdrain` | Read mode / write batch |
| `mc_bank` ×4 | Open row, same-bank timing counters, auto-precharge, tRFCpb, idle time, RAA count |
| `mc_chan` | Channel timing counters per bank group, tFAW window, tRFC blackout |
| `mc_refresh` | Owed refreshes, the bank to refresh next, the refresh hold |
| `mc_sched` | Next command per request, readiness, column and row picks, auto-precharge decision, timer PRE, refresh and RFM commands |
| `mc_resp` | Tags, read-return FIFO, write-data pipeline, in-order response buffer |
| `dram_model` | Banks, open rows, memory array, two command buses, read/write data pipelines, tRFC and tRFCpb, `access_err` |
| `mem_ctrl_top` | Instantiates `host_if`, `mem_ctrl`, `dram_model` |

---

## 10. Implementation status / 구현 상태

| Item | Status |
|------|--------|
| v4 controller, parameters above | done |
| Timing and protocol checker, host SVA (bind) | `tb/dram_timing_checker.sv`, `tb/host_if_checker.sv` |
| Directed TB (6 scenarios) and random TB (6 patterns, 32 bins, 15 build variants) | `tb/` |
| Area and timing flow | `make ppa` (`syn/ppa.sh`) |
| Negative tests that drive `dram_model` directly | TODO |
| Traffic × policy matrix, area and timing per feature | TODO (next step) |
