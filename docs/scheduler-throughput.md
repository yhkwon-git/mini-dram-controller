# Scheduler latency & throughput note / 스케줄러·처리량 노트

1-page PPA-style note for the v1 `mem_ctrl`: depth-4 request queue, 4 bank engines, one-command-per-cycle arbiter, in-order responses.  
Timing from `dram_pkg` / `docs/spec.md`. Not silicon PPA — cycle counts measured on `tb_mem_ctrl` waveforms; details in the [portfolio deck](../portfolio-deck/MiniDramController_Portfolio.pdf).

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

Each bank engine counts its own `tRCD` / `tRP` / `tRAS`, so while one bank waits, the arbiter can issue another bank's ACT / PRE / RD / WR. Still one DRAM command per cycle, and host responses stay in order (16-entry response buffer, ≤ 15 requests in flight).

---

## 2. Measured host latency (cycles)

Accept → response handshake with `rsp_ready = 1`, from the `tb_mem_ctrl` run. v0 = the single-FSM controller (commit `64e73e0`) driven by the same TB. The tag fix after `6049e5a` only limits acceptance at 15 in flight, so these numbers hold for HEAD.

| Class | v0 | v1 | Where v1's extra cycles come from |
|-------|---:|---:|------------------------------------|
| Page hit RD | 4 | 6 | queue stage +1, response buffer +1 |
| Closed-bank RD | 7 | 10 | + wait→issue handoff +1 (RD goes out the cycle after `ACT_WAIT` ends) |
| Closed-bank WR | 6 | 9–12 | same; the range is arbitration against other banks |
| Row-conflict RD | 11 | 14 | handoff after both `PRE_WAIT` and `ACT_WAIT` |
| Row-conflict WR | 10 | 13–14 | same |

Write hits do not occur in the TB.

---

## 3. Throughput

| Metric | v0 | v1 |
|--------|---:|---:|
| 4 writes to 4 banks, first accept → last response | 35 cycles | 17 cycles (2.06×) |
| Bank engines busy in the same cycle during the burst | 1 | up to 4 |
| Back-to-back RD | — | ≤ 1 per 4 cycles (single read pipe, `rd_inflight`) |

During the burst a command goes out every cycle for 8 cycles — with 4 banks the single command slot, not bank timing, becomes the limit.

**Refresh tax:** requests are blocked while REF is due or active (drain + `tRFC`). Measured over the TB run: 18.3 % of cycles (estimate `tRFC / tREFI = 12/64 ≈ 19 %`).

---

## 4. Tradeoffs (v1)

| Choice | Benefit | Cost |
|--------|---------|------|
| Leave page open (no auto-PRE) | Hit reuse; multi-bank locality | Row conflicts need PRE+ACT |
| Drain-then-REF | Simple, predictable | Latency bubble; REF closes every open row |
| Depth-4 queue + bank engines | Hides per-bank waits; multi-outstanding host | +2–3 cycles on an isolated request; 1 cmd/cycle; 1 RD pipe |
| In-order responses via tags | Simple host contract | Early finishers wait in a 16 × 32b buffer (about half of all flops) |
| Shadow open-row in `mem_ctrl` | Schedule without peeking at the model | Must stay consistent with `dram_model` |

**Next levers:** issue on the wait-exit cycle (−1 cycle per `tRCD` / `tRP`), hit-first dispatch, auto-PRE policy, overlap REF with other-bank traffic, shrink the response buffer together with the in-flight cap.

---

## 5. TB evidence

`make sim` directed cases (see TB `$display`):

1. Page hit WR→RD  
2. Same-bank page miss (row change); both rows’ data OK  
3. Multi-bank; bank0 conflict while bank1 stays open  
4. 4-bank write burst; ≥ 2 bank engines busy at once (observed 4)  
5. Response back-pressure: 20 reads with `rsp_ready` low, all returned in order  
