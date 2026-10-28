# Scheduler latency & throughput note / 스케줄러·처리량 노트

1-page PPA-style note for the v1 **single-outstanding** `mem_ctrl` FSM.  
Timing from `dram_pkg` / `docs/spec.md`. Not silicon PPA — analytical + TB-backed behavior.

| Knob | Value |
|------|------:|
| `tRCD` / `tRP` / `tRAS` / `tRC` | 3 / 3 / 6 / 9 |
| `tCL` / `tWR` | 2 / 2 |
| `tREFI` / `tRFC` | 64 / 12 |
| Banks | 4 (open-page, leave row open after RD/WR) |

---

## 1. What the scheduler optimizes

| Path | Controller action | Host-visible cost driver |
|------|-------------------|---------------------------|
| **Page hit** | Skip ACT → RD/WR | `tCL` (RD) or `tWR` (WR) |
| **Cold miss** (bank closed) | ACT → wait `tRCD` → RD/WR | `tRCD` + CAS/WR |
| **Row conflict** (same bank, wrong row) | wait `tRAS` if needed → PRE → `tRP` → ACT → `tRCD` → RD/WR | ≈ `tRP+tRCD` (+ residual `tRAS`) |
| **Other bank** | Independent open row | Hit latency if that bank’s row already open |

Current RTL: **depth-4 host queue** + **per-bank timers in parallel**, still **one DRAM command per cycle** and **in-order host responses**. Multi-bank hides `tRCD`/`tRP` of one bank behind another bank’s commands (TB burst peaked at 4 banks open).

---

## 2. Approximate host latency (cycles)

Counts are **accept → response handshake**, steady `rsp_ready=1`, ignoring REF. ±1–2 cycles of FSM/handshake overhead.

| Scenario | RD (cycles) | WR (cycles) | Rough formula |
|----------|------------:|------------:|---------------|
| Page hit | ~4–5 | ~3–4 | RD: `≈ 1 + tCL + rsp`; WR: `≈ 1 + tWR + rsp` |
| Cold miss (closed bank) | ~7–9 | ~6–8 | `≈ 1 + tRCD + (tCL\|tWR) + rsp` |
| Row conflict (PRE needed, `tRAS` done) | ~10–13 | ~9–12 | `≈ 1 + tRP + tRCD + (tCL\|tWR) + rsp` |
| Row conflict + remaining `tRAS` | higher | higher | add leftover `ras_rem` before PRE |

**Multi-bank example:** bank0 row A open + access bank1 row B (closed) → bank1 pays **cold miss**, bank0 stays open; next access to bank0 row A is still a **hit**. TB scenario 3 covers this (`tb/tb_mem_ctrl.sv`).

---

## 3. Throughput (single outstanding)

Peak sustained rate ≈ `1 / L` txn/cycle for a workload with average latency `L`.

| Mix | Avg L (illustrative) | Relative txn rate |
|-----|---------------------:|------------------:|
| 100% hit RD | ~5 | 1.00× (baseline) |
| 100% cold miss RD | ~8 | ~0.6× |
| 100% row-conflict RD | ~12 | ~0.4× |
| 50% hit / 50% conflict | ~8.5 | ~0.6× |

**Refresh tax:** every `tREFI` clocks, IDLE prefers REF (`tRFC` busy ≈ 12). At hit-only traffic, REF steals roughly `tRFC / tREFI ≈ 12/64 ≈ 19%` of wall time when the counter always expires in IDLE — lower if traffic delays the slot.

---

## 4. Tradeoffs (v1)

| Choice | Benefit | Cost |
|--------|---------|------|
| Leave page open (no auto-PRE) | Hit reuse; multi-bank locality | Row conflicts need PRE+ACT; more open-page state |
| Refresh over new req at IDLE | Simple, predictable | Adds latency bubbles; no bank-smart REF |
| Depth-4 queue + bank-parallel waits | Hide per-bank latency; multi-outstanding host | Still 1 cmd/cycle; in-order rsp; 1 RD pipe |
| Shadow open-row in `mem_ctrl` | Schedule without model peek | Must stay consistent with `dram_model` |

**Next levers (not in v1):** cmd queue + bank scoreboard, prefer hit over miss, auto-PRE policy, overlapping REF with other-bank traffic.

---

## 5. TB evidence

`make sim` directed cases (see TB `$display`):

1. Page hit WR→RD  
2. Same-bank page miss (row change); both rows’ data OK  
3. Multi-bank open; bank0 conflict while bank1 stays open  

No cycle-accurate scoreboard yet — latencies above are **FSM-derived**. Optional follow-up: cycle counters in TB around `host_read`/`host_write`.
