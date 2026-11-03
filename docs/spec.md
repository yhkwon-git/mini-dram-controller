# Mini DRAM Controller Spec / 미니 DRAM 컨트롤러 스펙

**Scope:** `host_if` → `mem_ctrl` (request queue + bank engines + arbiter) → `dram_model`  
**Source of truth for constants:** `rtl/dram_pkg.sv`  
**Clock:** single sync domain (`clk`, active-low `rst_n`). Timing is in **clock cycles**.

---

## 1. Geometry & address map / 주소 맵

| Symbol | Value | Meaning |
|--------|------:|---------|
| `NUM_BANKS` | 4 | banks |
| `ROW_BITS` | 8 | 256 rows / bank |
| `COL_BITS` | 4 | 16 columns / row |
| `DATA_BITS` | 32 | word width |
| `ADDR_BITS` | 14 | `$clog2(NUM_BANKS)+ROW_BITS+COL_BITS` |

**Packed host address** `[ADDR_BITS-1:0]` (MSB→LSB):

```
[ bank | row | col ] = [13:12 | 11:4 | 3:0]
```

Helpers in `dram_pkg`: `addr_bank`, `addr_row`, `addr_col`.  
한 워드 = 한 (bank, row, col). Burst 없음 (v1).

---

## 2. Timing parameters / 타이밍 파라미터

Own model values (cycles). Tunable in `dram_pkg`.

| Param | Cycles | Rule |
|------:|-------:|------|
| `tRCD` | 3 | ACT → first RD/WR on that bank |
| `tRP` | 3 | PRE → next ACT on that bank |
| `tRAS` | 6 | ACT → PRE (minimum open time) |
| `tRC` | 9 | ACT → ACT same bank (`≈ tRAS + tRP`) |
| `tRFC` | 12 | REF busy window (`dram_model.busy`) |
| `tCL` | 2 | RD → `data_valid` / rdata |
| `tWR` | 2 | last WR → PRE (write recovery) |
| `tREFI` | 64 | refresh opportunity period (host clocks) |

**Per-bank tracking in `dram_model`:** open/closed + open row → page **hit** (same bank & row open) vs **miss** (closed or wrong row).

---

## 3. Command set / 명령 (`dram_cmd_e`)

| Cmd | Code | Effect on `dram_model` |
|-----|------|-------------------------|
| `CMD_NOP` | `000` | idle |
| `CMD_ACT` | `001` | open `row` on `bank` |
| `CMD_RD` | `010` | read `(bank,row,col)` → `rdata` after `tCL` |
| `CMD_WR` | `011` | write `wdata` to `(bank,row,col)` |
| `CMD_PRE` | `100` | close `bank` (v1: single-bank PRE) |
| `CMD_REF` | `101` | close all banks; busy for `tRFC` |

The controller issues at most one command per cycle: each bank engine raises a request (`want_pre` / `want_act` / `want_wr` / `want_rd`) and the arbiter picks one — PRE > ACT > WR > RD, round-robin across banks within a class.

---

## 4. Host interface / 호스트 IF (`host_if`)

Simple valid/ready (AXI-lite 대체 가능; `host_if`는 현재 조합 pass-through).

**Request** (host → ctrl): `req_valid` / `req_ready`, `req_write` (1=WR, 0=RD), `req_addr[13:0]`, `req_wdata[31:0]`  
**Response** (ctrl → host): `rsp_valid` / `rsp_ready`, `rsp_rdata[31:0]`, `rsp_err`

| Rule | Detail |
|------|--------|
| Accept | `req_ready` = free queue slot (depth 4) && no refresh due/active && a free response tag (≤ 15 requests in flight) |
| Order | Responses return in request order (`tag_retire`). Banks may finish out of order; finished data waits in the 16-entry response buffer |
| Complete | RD: after model `data_valid`; WR: after `tWR` recovery, with `rsp_rdata = 0` |
| Backpressure | While `rsp_ready = 0`, finished responses wait in the buffer; new requests stop once 15 are in flight |
| `rsp_err` | Reserved (illegal addr / protocol); v1 drives 0 |

---

## 5. `mem_ctrl` scheduler / 스케줄러

Request queue (depth 4) → dispatch → **bank engine ×4** (one `b_state` per bank) → command arbiter → `dram_model`.

| Stage | Rule |
|-------|------|
| Dispatch | Oldest queue entry (by tag) whose bank is `ST_IDLE`; one per cycle. Paused while REF is being issued or is active |
| Page policy | Decided at dispatch from the shadow `bank_open` / `bank_row`: hit → `ST_RD` / `ST_WR` (skip ACT); open, other row → `ST_PRE` then ACT; closed → `ST_ACT` |
| Arbiter | One command per cycle among `want_*`: PRE > ACT > WR > RD, round-robin from `rr_ptr`. RD only when no read is in flight (single data pipe in the model) |
| Timing | `ras_rem` / `rc_rem` gate PRE / ACT (tRAS / tRC); `b_timer` counts tRP / tRCD / tWR in the `*_WAIT` states |
| Completion | WR: `ST_WR_WAIT` exit marks the tag done. RD: model `data_valid` marks the tag done. The bank returns to `ST_IDLE` |

Bank engine paths (`ctrl_state_e`):

```
dispatch ─┬─ hit ──────────────────────────────────────────────► ST_RD / ST_WR
          ├─ bank closed ──────────────────────► ST_ACT ─► ST_ACT_WAIT (tRCD) ─┘
          └─ bank open, other row ─► ST_PRE ─► ST_PRE_WAIT (tRP) ─► ST_ACT

ST_RD ─► ST_RD_WAIT (data_valid) ─► ST_IDLE
ST_WR ─► ST_WR_WAIT (tWR)        ─► ST_IDLE
```

`ST_REF` / `ST_REF_WAIT` / `ST_ERROR` are reserved in the enum and unused in v1 — refresh is a controller-wide `ref_active` flag (§6).

A wait state only changes the bank state when its timer reaches 0; the next command goes out one cycle later through the arbiter. Measured ACT→RD/WR and PRE→ACT gaps are therefore `tRCD + 1` and `tRP + 1` — never shorter than the spec.

---

## 6. Refresh policy / 리프레시

| Item | Policy |
|------|--------|
| Counter | `refi_cnt` loads `tREFI` and counts down; it holds at 0 (`ref_due`) until REF is issued |
| Due | `ref_due` drops `req_ready` (no new requests); queued and in-progress requests still complete (drain) |
| Issue | `CMD_REF` once all banks are `ST_IDLE`, the queue is empty and the model is not busy. Finished responses may still be waiting for `rsp_ready` |
| Command | `CMD_REF` → model closes all banks, `busy` for `tRFC`; the controller clears its shadow open-row state |
| Reload | When `busy` drops, `ref_active` clears and `refi_cnt ← tREFI` |

The REF-to-REF interval is `tREFI` + drain time + `tRFC`, not exactly `tREFI`. No per-row refresh map in v1 — one global REF covers the model.

---

## 7. Block roles / 블록

| Module | Role |
|--------|------|
| `host_if` | Host↔ctrl valid/ready (combo pass-through now) |
| `mem_ctrl` | Request queue, dispatch + page policy, bank engines, cmd arbiter, refresh, response buffer |
| `dram_model` | Banks, open-row, mem array, `busy`/`data_valid`/`page_hit` |
| `mem_ctrl_top` | Instantiates the three |

---

## 8. Implementation status / 구현 상태

| Item | Status |
|------|--------|
| Params, enums, address helpers | in `dram_pkg` |
| Request queue (`QUEUE_DEPTH=4`) + per-bank engines + cmd arbiter | in `mem_ctrl` |
| At most 15 requests in flight (response tags never wrap) | in `mem_ctrl` |
| Model ACT/RD/WR/PRE/REF + tCL/tRFC + `access_err` | in `dram_model` |
| Directed TB: hit / miss / multi-bank / 4-bank burst / response back-pressure | in `tb/tb_mem_ctrl.sv` |
| Command-spacing assertions, negative tests, random traffic | **TODO** (see `docs/coverage.md`) |
