# Mini DRAM Controller — Own Spec (Stub)

> **Educational / portfolio only.** Timing numbers and commands are **placeholders**.  
> This is **not** JEDEC DDR/LPDDR/HBM compliant and makes **no** confidential or product claims.

Status: **skeleton** — parameters and FSM state list defined; full scheduler TBD.

---

## 1. Goal

Host request/response bus → memory controller (command schedule + timing FSM) → simple synchronous DRAM model with banks and open-page tracking.

---

## 2. Address map (educational)

| Field | Width | Notes |
|-------|-------|--------|
| bank  | `$clog2(NUM_BANKS)` | default `NUM_BANKS=4` → 2 bits |
| row   | `ROW_BITS` | default 8 → 256 rows/bank |
| col   | `COL_BITS` | default 4 → 16 cols/row |
| **total** | `ADDR_BITS` | packed `[bank \| row \| col]` |

Data width: `DATA_BITS = 32`.

See `rtl/dram_pkg.sv` for the single source of truth.

---

## 3. Timing parameters (placeholders, clock cycles)

| Param | Default | Meaning (educational) |
|-------|---------|------------------------|
| `tRCD` | 3 | ACT → RD/WR |
| `tRP`  | 3 | PRE → ACT |
| `tRAS` | 6 | ACT → PRE (min) |
| `tRC`  | 9 | ACT → ACT same bank (approx) |
| `tRFC` | 12 | REF busy window |
| `tCL`  | 2 | RD data return latency |
| `tWR`  | 2 | WR recovery before PRE |
| `tREFI`| 64 | refresh opportunity interval |

**Do not treat these as real DRAM datasheet values.**

---

## 4. DRAM commands

`NOP`, `ACT`, `RD`, `WR`, `PRE`, `REF` — see `dram_pkg::dram_cmd_e`.

---

## 5. Controller FSM states (skeleton)

```
ST_IDLE
ST_ACT → ST_ACT_WAIT
ST_RD  → ST_RD_WAIT
ST_WR  → ST_WR_WAIT
ST_PRE → ST_PRE_WAIT
ST_REF → ST_REF_WAIT
ST_ERROR
```

Current RTL walks a naïve ACT→RD/WR path and a stub REF when `tREFI` expires.  
**Not yet implemented:** bank-conflict policy, page hit/miss prefer, true timing waits, write recovery, auto-PRE, multi-request queue.

---

## 6. Host interface

Simple valid/ready request + response (`host_if.sv`). AXI-lite slave can replace this later without changing the DRAM model.

---

## 7. Verification plan (roadmap)

| Phase | Item |
|-------|------|
| Now | Verilator compile + idle smoke TB |
| Next | Directed WR→RD, bank conflict, refresh during traffic |
| Later | Coverage (cmd/state), waves note, 1p PPA/throughput |

---

## 8. Out of scope

- Real JEDEC/HBM timing, PHY, stacking, ECC, DFT  
- Production QoS / multi-port SoC integration  
- Claiming compliance with any commercial DRAM product
