# Scheduler latency & throughput note / 스케줄러·처리량 노트

PPA-style note for the four controller versions. Timing from `dram_pkg` / `docs/spec.md` (own scaled model, not JEDEC). Cycle counts come from the testbenches; area and timing from `make ppa`. Numbers for v3 are from commit `1b0943a`, for v2 from `c1b8248`, for v1 from `2eabd33` (latency, random traffic) and `fa08330` (PPA).

| Version | Structure |
|---------|-----------|
| v0 | single FSM, one request at a time |
| v1 | depth-4 queue, 4 bank engines (one request per bank), one command per cycle, one RD in flight, drain-then-REF |
| v2 | depth-8 queue with an age matrix, command-level FR-FCFS scheduler, up to 4 RDs in flight, one REF owed per tREFI (PREA then REF) |
| v3 | read queue 8 + write queue 8, posted writes and forwarding, write batches by watermark, page policies (open, close, timer), address maps (XOR default) |

---

## 1. Isolated latency (cycles)

Accept → response handshake with `rsp_ready = 1`, one request at a time from `tb_mem_ctrl`.

| Class | v0 | v1 | v2 | v3 | Why v3 differs from v2 |
|-------|---:|---:|---:|---:|-------------------------|
| Page hit RD | 4 | 6 | 5 | 5 | same |
| Closed-bank RD | 7 | 10 | 8 | 8 | same |
| Row-conflict RD | 11 | 14 | 11 | 11 | same |
| WR, any bank state | 6–10 | 9–14 | 6–9 | 1 | posted: the response is ready on the accept edge |
| RD to an address in the write queue | – | – | – | 1 | forwarded from the youngest queued write; no DRAM access |

## 2. Throughput

### Back-to-back requests (no gap, no back-pressure, seed 1, 5,000 requests)

Data bus busy = cycles with read or write data on the DRAM bus.

| Traffic | v1 | v2 | v3 | v3 with the v2 map | v3 read latency avg |
|---------|---:|---:|---:|---:|---:|
| row hit, reads only | 19.9% | 66.7% | 66.7% | 66.7% | 18.7 |
| row hit, writes only | 51.1% | 63.8% | 64.3% | 64.3% | – |
| row hit, half and half | 33.3% | 50.8% | 51.4% | 51.4% | 23.1 |
| sequential, reads only | 15.0% | 50.5% | 58.8% | 50.5% | 16.6 |
| random, reads only | 15.8% | 23.3% | 22.9% | 23.3% | 49.6 |
| mixed patterns, half and half | 14.1% | 18.5% | 22.2% | 18.8% | 63.7 |

With the same address map v3 saturates where v2 does: the write queue and write batches change turnarounds and write latency, not peak throughput. The sequential and mixed gains come from the XOR map.

What still limits v3:

- **Refresh, about a third of the time.** Every tREFI (64) the controller precharges all banks, waits tRP and tRFC, and reopens the rows: about 25 cycles. The scaled model's tRFC/tREFI is 12/64, far above a real device, so refresh weighs more here than in silicon. Per-bank refresh is the lever.
- **One command bus.** A random-address request needs PRE, ACT and RD: three command slots for one data beat, so at most about 33%. Close page with auto-precharge cuts that to two (§ 3); separate row and column command buses (as in HBM) remove the limit.

### Random regression (request gap 0–2 cycles, 50 seeds per pattern)

| Pattern | v2 busy | v3 busy | v2 latency | v3 latency | v3 read latency p99 | REF interval (v3) |
|---------|---:|---:|---:|---:|---:|---:|
| seq | 26.9% | 34.8% | 47.2 | 33.2 | 89.4 | 63.9 |
| rowhit | 34.5% | 34.6% | 34.5 | 32.1 | 88.6 | 63.9 |
| mixed | 18.4% | 21.3% | 69.3 | 61.3 | 133.2 | 63.7 |
| rand | 20.1% | 20.3% | 62.3 | 64.6 | 131.3 | 63.7 |
| hotbank | 10.2% | 10.0% | 102.8 | 137.1 | 242.3 | 63.9 |
| stride | 8.8% | 21.9% | 103.9 | 59.5 | 121.5 | 63.7 |

- `stride` steps 16 words. Under v2's bank:row:col map that is the next row of the same bank, a conflict every time; under XOR it walks the four banks.
- `hotbank` latency grows with the queue: throughput is the same, and 16 entries instead of 8 hold more requests waiting for bank 0 (Little's law). The `depth4` build (4 + 4 entries) brings the read latency to 31.1.

## 3. Policies and maps (random regression, 10 seeds per pattern per build)

Data bus busy per pattern:

| Build | seq | rowhit | mixed | rand | hotbank | stride | avg |
|-------|---:|---:|---:|---:|---:|---:|---:|
| default (XOR, open, write batches) | 34.8 | 34.6 | 21.3 | 20.3 | 10.0 | 21.9 | 23.8 |
| `nodrain` (reads and writes oldest-first) | 34.6 | 34.4 | 21.5 | 20.2 | 10.1 | 21.6 | 23.7 |
| `close` (auto-precharge) | 34.6 | 34.1 | 22.0 | 21.4 | 10.0 | 23.7 | 24.3 |
| `timer` (PRE after 16 idle cycles) | 34.8 | 34.9 | 21.4 | 20.3 | 10.1 | 21.9 | 23.9 |
| `map_rbc` (row:bank:col) | 35.6 | 34.8 | 21.4 | 20.3 | 10.0 | 22.0 | 24.0 |
| `map_rcb` (row:col:bank) | 34.1 | 34.8 | 21.3 | 20.4 | 10.0 | 18.1 | 23.1 |
| `map_brc` (bank:row:col, v2) | 27.5 | 34.8 | 18.2 | 20.3 | 10.0 | 8.6 | 19.9 |
| `fcfs` | 35.0 | 34.9 | 21.3 | 20.4 | 9.9 | 21.9 | 23.9 |
| `depth4` (4 + 4 entries) | 33.8 | 34.1 | 20.1 | 19.1 | 9.7 | 20.7 | 22.9 |
| `rdpipe1` (one RD in flight) | 26.4 | 27.2 | 19.3 | 18.7 | 9.9 | 19.5 | 20.2 |

Read latency, RD↔WR turnarounds and row hit rate, averaged over the six patterns:

| Build | Read latency | Turnarounds per run | Row hit rate |
|-------|---:|---:|---:|
| default | 65.2 | 1,269 | 34.5% |
| `nodrain` | 66.8 | 1,783 | 34.9% |
| `close` | 63.5 | 1,297 | 27.5% |
| `timer` | 65.0 | 1,263 | 33.8% |
| `map_rbc` | 65.0 | 1,257 | 34.8% |
| `map_rcb` | 67.9 | 1,333 | 42.6% |
| `map_brc` | 86.1 | 1,243 | 34.2% |

- **Write batches** leave throughput where it was (23.8 vs 23.7%), cut turnarounds by 29% and read latency by 2.4%. FR-FCFS already groups each direction: during tWTR or tRTW the other direction's commands are not ready, so the same direction keeps going. The first cut banned the other queue outright and lost up to 12% (seed 1); the mode now only sets priority.
- **Close page** gains 5–8% on `rand` and `stride`, where a RD/WR with auto-precharge saves the PRE slot of the next conflict, and loses 1.4% on `rowhit`, where the row hit rate falls from 83% to 56%.
- **Timer** is close to open page: refresh closes every row each tREFI, so a 16-cycle idle timeout rarely fires under load.
- **Maps**: XOR and row:bank:col tie on these patterns (both spread a 16-word stride); they differ on a 64-word stride, which row:bank:col keeps on one bank. row:col:bank interleaves consecutive words, but a 16-word stride leaves the two bank bits unchanged: `stride` stays on one bank, gets row hits (65%) and no bank parallelism, and loses 17%.
- **FCFS vs FR-FCFS**: equal here (23.9 vs 23.8%). Refresh closes every row each tREFI, which bounds how many hits FR-FCFS can collect.

## 4. Area and timing (`make ppa`, Nangate45 typical)

| | v0 | v1 (`fa08330`) | v2 (`c1b8248`) | v3 first cut (not committed) | v3 (`1b0943a`) |
|---|---:|---:|---:|---:|---:|
| Area (µm²) | 1,208 | 9,692 | 13,478 | 19,263 | 18,600 |
| FF | 131 | 1,072 | 1,344 | 1,582 | 1,582 |
| reg2reg (ns) | 0.809 | 2.880 | 2.753 | 4.765 | 2.922 |
| ≈ fmax (MHz) | 1,182 | 343 | 357 | 208 | 337 |

The first v3 cut ran its accept path through the scheduler: the queue's same-address `match` left out the entry whose RD/WR issued this cycle, so `req_ready`, forwarding and the push enables waited for the pick. Three changes brought it back:

1. `match` keeps the leaving entry (forwarding from it returns the same data; holding a write one extra cycle is harmless): the accept path no longer goes through the scheduler.
2. One column and one row candidate set ("the selected queue's, else the other queue's") instead of five separate selections, and no dependency clear on pop (`q_valid` already masks it): 3.745 ns.
3. The pick stays one-hot from the scheduler to the queue pop and the tag and write-data selects, instead of an index that was encoded and decoded again (a fanout-72 net): 2.922 ns.

With `WDRAIN = 1` the cross-queue age matrix (`mc_xage`) and the bank idle counters are unused and synthesis removes them; they cost area only in the builds that use them. ABC maps without a timing target, so small netlist changes move the result by a few percent; every column is `make ppa` rerun on its own commit.

## 5. Tradeoffs (v3)

| Choice | Benefit | Cost |
|--------|---------|------|
| Command-level scheduler | issues each request's next command as soon as it is legal; serves several hits to one row back to back | per-cycle logic over 16 entries |
| FR-FCFS + row protection | row hits first: higher hit rate and throughput | needs a starvation guard |
| Read and write queues | writes do not take read entries; the read queue stores no data | 16 entries, cross-queue age (only with `WDRAIN = 0`) |
| Posted writes + forwarding | 1-cycle write response; 39,047 RAW reads answered without the DRAM (default build) | a write to an address in the read queue waits on the port |
| Write batches | −29% turnarounds, −2.4% read latency | no throughput gain in this model |
| XOR address map | 2.5× on 16-word strides, +29% on sequential traffic | relies on bank parallelism rather than long row hits |
| Close page | +5–8% on low-locality traffic | −1.4% on row-hit traffic |
| One-hot pick | no encode/decode stage | AND-OR select trees |
| In-order responses via tags | simple host contract | 16 × 32b buffer, 35% of the FFs |

**Next levers:** separate row/column command buses, per-bank refresh and bank groups, a traffic × policy matrix with 64-word strides, a smaller response buffer.

---

## Appendix: v1 measurements

4 writes to 4 banks, first accept → last response: v0 35 cycles, v1 17 cycles (2.06×), v2 15 cycles (the host task accepts only every 2 cycles in this scenario, which bounds all three). v1 refresh blocked requests for 23.3% of the `make sim` run (194 of 834 cycles after reset, 10 REFs), because each REF waited for the queue to drain and the counter reloaded only after the REF.

![v1 4-bank write burst: four bank engines overlap; first accept to last response is 17 cycles](images/wave_4bank_burst.png)

<sub>v1, TB scenario 4, commit `6049e5a`. ① b0 accept; b1–b3 arrive 2 cycles apart and dispatch at once. ② When b0 and b2 both wait for ACT, `rr_ptr` sends b2 first; a command goes out every cycle here. ③ b2's WR (bank was closed) finishes before b0 and b1, which need PRE. ④ Responses leave in tag order (b0 → b1 → b2 → b3) over 4 cycles; b2 waits in the buffer.</sub>
