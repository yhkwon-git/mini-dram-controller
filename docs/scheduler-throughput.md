# Scheduler latency & throughput note / 스케줄러·처리량 노트

PPA-style note for the five controller versions. Timing from `dram_pkg` / `docs/spec.md` (own scaled model, not JEDEC). Cycle counts come from the testbenches; area and timing from `make ppa`. Numbers for v4 are from commit `ab9d522`, for v3 from `1b0943a`, for v2 from `c1b8248`, for v1 from `2eabd33` (latency, random traffic) and `fa08330` (PPA).

| Version | Structure |
|---------|-----------|
| v0 | single FSM, one request at a time |
| v1 | depth-4 queue, 4 bank engines (one request per bank), one command per cycle, one RD in flight, drain-then-REF |
| v2 | depth-8 queue with an age matrix, command-level FR-FCFS scheduler, up to 4 RDs in flight, one REF owed per tREFI (PREA then REF) |
| v3 | read queue 8 + write queue 8, posted writes and forwarding, write batches by watermark, page policies (open, close, timer), address maps (XOR default) |
| v4 | separate row and column command buses, bank groups (tCCD/tRRD/tWTR short and long), per-bank refresh, refresh management (RFM) |

From v4 on the DRAM model has bank groups. A v3-style build on the same device (`bus1_refab`: one command bus, all-bank refresh) is the like-for-like baseline.

---

## 1. Isolated latency (cycles)

Accept → response handshake with `rsp_ready = 1`, one request at a time from `tb_mem_ctrl`.

| Class | v0 | v1 | v2 | v3 | v4 |
|-------|---:|---:|---:|---:|---:|
| Page hit RD | 4 | 6 | 5 | 5 | 5 |
| Closed-bank RD | 7 | 10 | 8 | 8 | 8 |
| Row-conflict RD | 11 | 14 | 11 | 11 | 11 |
| WR, any bank state | 6–10 | 9–14 | 6–9 | 1 | 1 |
| RD to an address in the write queue | – | – | – | 1 | 1 |

In the same directed sequence, one read under v3 took 23 cycles because an all-bank refresh came first; under v4 the refresh holds one bank and the same read takes 5.

## 2. Throughput

### Back-to-back requests (no gap, no back-pressure, seed 1, 5,000 requests)

Data bus busy = cycles with read or write data on the DRAM bus. The middle columns are v4 built with one feature at a time, on the bank-group device.

| Traffic | v1 | v2 | v3 | v3-style (`bus1_refab`) | buses only (`refab`) | per-bank refresh only (`bus1`) | v4 | v4 + row:col:bank |
|---------|---:|---:|---:|---:|---:|---:|---:|---:|
| row hit, reads only | 19.9% | 66.7% | 66.7% | 63.3% | 65.6% | 71.8% | 80.7% | 80.7% |
| row hit, writes only | 51.1% | 63.8% | 64.3% | 60.4% | 62.1% | 72.3% | 80.7% | 80.7% |
| row hit, half and half | 33.3% | 50.8% | 51.4% | 47.3% | 47.8% | 55.2% | 59.6% | 59.6% |
| sequential, reads only | 15.0% | 50.5% | 58.8% | 39.7% | 40.2% | 48.0% | 50.0% | 78.5% |
| random, reads only | 15.8% | 23.3% | 22.9% | 21.9% | 23.4% | 24.7% | 26.5% | 27.1% |
| mixed patterns, half and half | 14.1% | 18.5% | 22.2% | 21.7% | 22.7% | 24.3% | 25.7% | 25.6% |

- **Per-bank refresh is the largest single lever** (row-hit reads 63.3 → 71.8%). An all-bank REF closes every row and stops everything for about 25 cycles each tREFI; a REFpb holds one bank for tRFCpb (8), at a moment when no queued request needs it.
- **The buses pay off with per-bank refresh** (alone +1–7% by pattern; together 71.8 → 80.7%). Refresh PREs and REFpbs and other banks' ACTs go on the row bus and stop interrupting the RD stream on the column bus.
- **Bank groups change the best map.** Two column commands in one group need tCCD_L (2). XOR keeps 16 consecutive words in one bank, so sequential reads stop at 50%; row:col:bank changes group every two words and reaches 78.5%. It keeps a 16-word stride on one bank, though, so its regression average is lower (§ 3).
- **Random reads** were capped near 33% by three command slots per request on one bus; now tRC (9), tFAW and refresh set the limit.

### Random regression (request gap 0–2 cycles, 50 seeds per pattern)

| Pattern | v3 busy | v4 busy | v3 latency | v4 latency | v4 read latency p99 | v4 refresh interval per bank |
|---------|---:|---:|---:|---:|---:|---:|
| seq | 34.8% | 33.7% | 33.2 | 34.6 | 93.4 | 63.9 |
| rowhit | 34.6% | 36.0% | 32.1 | 30.3 | 86.7 | 64.0 |
| mixed | 21.3% | 24.1% | 61.3 | 53.6 | 127.5 | 60.7 |
| rand | 20.3% | 24.1% | 64.6 | 53.5 | 121.0 | 58.9 |
| hotbank | 10.0% | 10.2% | 137.1 | 135.1 | 239.9 | 58.8 |
| stride | 21.9% | 26.8% | 59.5 | 47.3 | 108.3 | 57.2 |

- Conflict-heavy traffic gains most (rand +19%, stride +22%, mixed +13%): PRE and ACT no longer take column slots, and refresh holds one bank.
- `seq` is 3% lower: the bank-group penalty under the XOR map (above).
- The refresh interval per bank is below 64 where RFM adds REFpbs. At most one refresh was owed (v3: 4).

## 3. Policies, maps and v4 features (random regression, 10 seeds per pattern per build)

Data bus busy per pattern:

| Build | seq | rowhit | mixed | rand | hotbank | stride | avg |
|-------|---:|---:|---:|---:|---:|---:|---:|
| default (two buses, per-bank refresh, RFM, XOR, open, write batches) | 33.7 | 36.0 | 24.1 | 24.1 | 10.2 | 26.8 | 25.8 |
| `bus1` (one command bus) | 33.2 | 35.9 | 23.0 | 22.8 | 10.1 | 24.7 | 25.0 |
| `refab` (all-bank refresh) | 32.3 | 35.0 | 21.8 | 21.5 | 9.5 | 23.9 | 24.0 |
| `bus1_refab` (v3-style) | 32.1 | 34.9 | 20.8 | 20.1 | 9.5 | 21.8 | 23.2 |
| `rfm_late` (RFM only at the limit) | 33.7 | 36.2 | 24.0 | 24.2 | 10.1 | 26.7 | 25.8 |
| `nodrain` (reads and writes oldest-first) | 33.6 | 36.1 | 24.1 | 24.3 | 10.3 | 27.2 | 25.9 |
| `close` (auto-precharge) | 33.5 | 35.3 | 24.2 | 24.8 | 10.2 | 27.7 | 26.0 |
| `timer` (PRE after 16 idle cycles) | 33.8 | 36.1 | 24.1 | 24.3 | 10.2 | 26.9 | 25.9 |
| `map_rbc` (row:bank:col) | 35.1 | 36.2 | 24.1 | 24.2 | 10.1 | 27.0 | 26.1 |
| `map_rcb` (row:col:bank) | 35.7 | 36.2 | 24.0 | 24.2 | 10.1 | 17.3 | 24.6 |
| `map_brc` (bank:row:col, v2) | 24.1 | 36.2 | 19.6 | 24.2 | 10.1 | 8.8 | 20.5 |
| `fcfs` | 33.9 | 36.2 | 23.8 | 24.2 | 10.1 | 26.8 | 25.8 |
| `depth4` (4 + 4 entries) | 33.4 | 35.9 | 23.6 | 23.9 | 10.0 | 26.8 | 25.6 |
| `rdpipe1` (one RD in flight) | 27.9 | 31.7 | 22.9 | 23.3 | 10.1 | 25.5 | 23.6 |

Read latency, RD↔WR turnarounds and row hit rate, averaged over the six patterns:

| Build | Read latency | Turnarounds per run | Row hit rate |
|-------|---:|---:|---:|
| default | 59.7 | 1,537 | 34.2% |
| `bus1` | 61.8 | 1,480 | 34.3% |
| `refab` | 65.0 | 1,358 | 34.7% |
| `bus1_refab` | 67.6 | 1,310 | 34.7% |
| `rfm_late` | 59.8 | 1,535 | 34.3% |
| `nodrain` | 60.6 | 1,896 | 34.4% |
| `close` | 59.0 | 1,528 | 26.9% |
| `timer` | 59.3 | 1,519 | 33.2% |
| `map_rbc` | 59.2 | 1,535 | 34.3% |
| `map_rcb` | 64.3 | 1,591 | 41.9% |
| `map_brc` | 83.3 | 1,388 | 34.0% |

- **Buses and refresh**: the default build is 11% above the v3-style build with 12% lower read latency. Per-bank refresh accounts for 7–8% (`bus1` vs `bus1_refab`, default vs `refab`), the separate buses for 3%.
- **RFM** costs about 5% on `hotbank` and 1% on `rand` against a v4 build without RFM (seed 3, not committed). Early RFM (`RFM_EARLY = 1`) and RFM only at the limit tie: under load an idle bank is rare, so an early REFpb seldom finds one.
- **Write batches** leave throughput where it was (25.8 vs 25.9%), cut turnarounds by 19% and read latency by 1.5%. FR-FCFS already groups each direction: during tWTR or tRTW the other direction is not ready. The first v3 cut banned the other queue outright and lost up to 12% (seed 1); the mode now only sets priority.
- **Close page** gains 3% on `rand` and `stride` (v3: 5–8%). Auto-precharge saves the PRE's command slot, and with two buses the PRE no longer competes with RD/WR. It loses 2% on `rowhit`, where the hit rate falls from 83% to 53%.
- **Timer** is close to open page: refresh closes every bank once per tREFI, so a 16-cycle idle timeout rarely fires under load.
- **Maps**: XOR and row:bank:col both spread a 16-word stride; they differ on a 64-word stride, which row:bank:col keeps on one bank. row:col:bank gives the best sequential numbers under bank groups but keeps a 16-word stride on one bank (−35%).

## 4. Area and timing (`make ppa`, Nangate45 typical)

| | v0 | v1 (`fa08330`) | v2 (`c1b8248`) | v3 first cut (not committed) | v3 (`1b0943a`) | v4 (`ab9d522`) |
|---|---:|---:|---:|---:|---:|---:|
| Area (µm²) | 1,208 | 9,692 | 13,478 | 19,263 | 18,600 | 18,912 |
| FF | 131 | 1,072 | 1,344 | 1,582 | 1,582 | 1,616 |
| reg2reg (ns) | 0.809 | 2.880 | 2.753 | 4.765 | 2.922 | 2.831 |
| ≈ fmax (MHz) | 1,182 | 343 | 357 | 208 | 337 | 348 |

fmax is 1 / min period, where the min period is the reg2reg arrival plus the capture flop's setup (v4: 2.831 + 0.043 = 2.874 ns, `min_period_ns` in the `make ppa` CSV). The same RTL times at 2.18 ns (458 MHz, HSL commit 3d596a4) in High-Speed Link Lite's chip STA, a different flow: the whole chip mapped hierarchically with `abc -D 1250 -constr` and fanout buffer trees, against `mem_ctrl` alone, flattened, with no timing target and no fanout buffering here. How much each difference contributes was not measured.

**v3.** The first cut ran its accept path through the scheduler: the queue's same-address `match` left out the entry whose RD/WR issued this cycle, so `req_ready`, forwarding and the push enables waited for the pick. Three changes brought it back: `match` keeps the leaving entry (forwarding from it returns the same data; holding a write one extra cycle is harmless); one column and one row candidate set instead of five separate selections, and no dependency clear on pop (`q_valid` already masks it), 3.745 ns; the pick stays one-hot to the queue pop and the tag and write-data selects instead of an index encoded and decoded again (a fanout-72 net), 2.922 ns.

**v4.** Faster than v3 despite more function: with one bus the scheduler chose between the column and the row pick (`use_col`, an age compare under FCFS) on the critical path; with two buses both picks issue and that stage is gone. Before RFM the build reached 2.612 ns (377 MHz, not committed); the per-bank RAA counters and the RFM command choice in front of the row bus bring it to 2.831 ns. +34 FF: per-group counters in `mc_chan`, RAA counters, the next refresh bank.

With `WDRAIN = 1` the cross-queue age matrix (`mc_xage`) and with `PAGE_POLICY = PAGE_OPEN` the bank idle counters are unused and synthesis removes them. ABC maps without a timing target, so small netlist changes move the result by a few percent; every column is `make ppa` rerun on its own commit.

## 5. Tradeoffs (v4)

| Choice | Benefit | Cost |
|--------|---------|------|
| Command-level scheduler | issues each request's next command as soon as it is legal; serves several hits to one row back to back | per-cycle logic over 16 entries |
| Row and column command buses | PRE and ACT do not take column slots; with per-bank refresh +27% on saturated row hits | two command interfaces; a guard against a PRE beside a column command on one bank |
| Per-bank refresh | other banks keep working; at most one refresh owed | four times as many refresh commands; each closes a bank |
| RFM (RAA counters) | keeps every bank under the RowHammer limit (131,879 times at the limit, no violation) | 20 FF; about 5% on `hotbank` |
| FR-FCFS + row protection | row hits first: higher hit rate and throughput | needs a starvation guard |
| Read and write queues | writes do not take read entries; the read queue stores no data | 16 entries, cross-queue age (only with `WDRAIN = 0`) |
| Posted writes + forwarding | 1-cycle write response; 37,434 RAW reads answered without the DRAM (default build) | a write to an address in the read queue waits on the port |
| Write batches | −19% turnarounds, −1.5% read latency (regression, six patterns; the analysis matrix's random load gives −1.7%) | no throughput gain in this model |
| XOR address map | 3× on 16-word strides, +40% on sequential traffic against bank:row:col | 16 consecutive words share a bank group, so sequential reads hit tCCD_L |
| One-hot pick | no encode/decode stage | AND-OR select trees |
| In-order responses via tags | simple host contract | 16 × 32b buffer, 34% of the FFs |

**Next levers:** a traffic × policy matrix with 64-word strides, a bank-group-interleaving map, a smaller response buffer.

---

## Appendix: v1 measurements

4 writes to 4 banks, first accept → last response: v0 35 cycles, v1 17 cycles (2.06×), v2 15 cycles (the host task accepts only every 2 cycles in this scenario, which bounds all three). v1 refresh blocked requests for 23.3% of the `make sim` run (194 of 834 cycles after reset, 10 REFs), because each REF waited for the queue to drain and the counter reloaded only after the REF.

![v1 4-bank write burst: four bank engines overlap; first accept to last response is 17 cycles](images/wave_4bank_burst.png)

<sub>v1, TB scenario 4, commit `6049e5a`. ① b0 accept; b1–b3 arrive 2 cycles apart and dispatch at once. ② When b0 and b2 both wait for ACT, `rr_ptr` sends b2 first; a command goes out every cycle here. ③ b2's WR (bank was closed) finishes before b0 and b1, which need PRE. ④ Responses leave in tag order (b0 → b1 → b2 → b3) over 4 cycles; b2 waits in the buffer.</sub>
