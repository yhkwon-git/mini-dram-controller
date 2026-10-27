# Mini DRAM Controller Spec / 미니 DRAM 컨트롤러 스펙

**Scope:** `host_if` → `mem_ctrl` (timing FSM) → `dram_model`  
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

Controller issues one command per cycle when leaving an issue state (`ST_ACT` / `ST_RD` / …).

---

## 4. Host interface / 호스트 IF (`host_if`)

Simple valid/ready (AXI-lite 대체 가능; 현재는 패스스루).

**Request** (host → ctrl): `req_valid` / `req_ready`, `req_write` (1=WR, 0=RD), `req_addr[13:0]`, `req_wdata[31:0]`  
**Response** (ctrl → host): `rsp_valid` / `rsp_ready`, `rsp_rdata[31:0]`, `rsp_err`

| Rule | Detail |
|------|--------|
| Accept | Only in `ST_IDLE` when `req_valid && req_ready` — latch addr/data/write |
| Complete | RD: `rsp_*` after model `data_valid`; WR: `rsp_*` after WR path + `tWR` policy |
| Backpressure | No new accept while FSM busy or refresh slot active |
| `rsp_err` | Reserved (illegal addr / protocol); v1 drives 0 |

---

## 5. `mem_ctrl` FSM / 상태머신

States (`ctrl_state_e`):  
`ST_IDLE`, `ST_ACT`, `ST_ACT_WAIT`, `ST_RD`, `ST_RD_WAIT`, `ST_WR`, `ST_WR_WAIT`, `ST_PRE`, `ST_PRE_WAIT`, `ST_REF`, `ST_REF_WAIT`, `ST_ERROR`

### Target transitions (구현 목표; 스켈레톤은 타이밍 대기 미완)

```
                    ┌── refi_cnt==0 ──► ST_REF ──► ST_REF_WAIT ──(!busy)──┐
                    │                                                      │
 ST_IDLE ───────────┴── req accept ──► [page policy] ─────────────────────┤
    ▲                    │                                                 │
    │                    ├─ miss, bank open: ST_PRE→ST_PRE_WAIT(tRP)→ST_ACT│
    │                    ├─ miss, bank closed: ST_ACT                      │
    │                    └─ hit: skip ACT → ST_RD / ST_WR                  │
    │                                                                      │
    │   ST_ACT → ST_ACT_WAIT (tRCD) → ST_RD / ST_WR                        │
    │   ST_RD  → ST_RD_WAIT (tCL / data_valid) → rsp handshake ────────────┤
    │   ST_WR  → ST_WR_WAIT (tWR) → rsp handshake ─────────────────────────┤
    │         (optional auto-PRE if closing) ST_PRE→ST_PRE_WAIT(tRP) ──────┤
    └──────────────────────────────────────────────────────────────────────┘
```

| State | Action | Exit |
|-------|--------|------|
| `ST_IDLE` | Wait req or refresh | → `ST_REF` or issue path |
| `ST_ACT` / `ST_ACT_WAIT` | Issue `ACT`; count `tRCD` | → `ST_RD` or `ST_WR` |
| `ST_RD` / `ST_RD_WAIT` | Issue `RD`; wait data | rsp done → `ST_IDLE` (or PRE) |
| `ST_WR` / `ST_WR_WAIT` | Issue `WR`; count `tWR` | rsp done → `ST_IDLE` (or PRE) |
| `ST_PRE` / `ST_PRE_WAIT` | Issue `PRE`; count `tRP` | → `ST_ACT` or `ST_IDLE` |
| `ST_REF` / `ST_REF_WAIT` | Issue `REF`; wait `!busy` | → `ST_IDLE`, reload `tREFI` |
| `ST_ERROR` | Sticky fault | reset only |

**Page policy (v1):** same bank+row open → hit (skip ACT); else PRE if open wrong row, then ACT. Enforce `tRAS` before PRE after ACT.

---

## 6. Refresh policy / 리프레시

| Item | Policy |
|------|--------|
| Counter | `refi_cnt` loads `tREFI`, decrements each cycle when not resetting after REF |
| Slot | When `refi_cnt==0` and FSM reaches `ST_IDLE`, prefer **REF over new host req** |
| During traffic | Finish current txn, return to `ST_IDLE`, then take REF |
| Command | `CMD_REF` → model closes all banks, `busy` for `tRFC` |
| Reload | On `ST_REF_WAIT` exit (`!dram_busy`), reload `refi_cnt ← tREFI` |

No per-row refresh map in v1 — one global REF covers the model.

---

## 7. Block roles / 블록

| Module | Role |
|--------|------|
| `host_if` | Host↔ctrl valid/ready (combo pass-through now) |
| `mem_ctrl` | Latch req, page/refresh policy, timing FSM, DRAM cmds |
| `dram_model` | Banks, open-row, mem array, `busy`/`data_valid`/`page_hit` |
| `mem_ctrl_top` | Instantiates the three |

---

## 8. Implementation status / 구현 상태

| Item | Status |
|------|--------|
| Params, enums, address helpers | in `dram_pkg` |
| Timing FSM + refresh slot + open-row policy | in `mem_ctrl` |
| Model ACT/RD/WR/PRE/REF + tCL/tRFC | in `dram_model` |
| Directed TB: hit / page-miss / multi-bank conflict | in `tb/tb_mem_ctrl.sv` |
| Model `access_err` + `bank_open_oh` observability | in `dram_model` / top |
| REF-under-load coverage | **TODO** |
