# Mini DRAM Controller + Simple DRAM Model

SystemVerilog mini DRAM memory controller with a simple synchronous DRAM model (own timing parameters, banks, open-page hit/miss).  
SystemVerilog 기반 미니 DRAM 메모리 컨트롤러 — 자체 타이밍 모델, 뱅크, 페이지 hit/miss, 요청 큐·뱅크 병렬 스케줄.

| | |
|--|--|
| **Repo** | https://github.com/yhkwon-git/mini-dram-controller |
| **Status** | Queue + bank-parallel scheduler; directed TB PASS |
| **License** | MIT |

---

## Overview / 구성

Host (`host_if`) → **depth-4 request queue** → **per-bank timing engines** + cmd arbiter → `dram_model`.

- Page hit/miss + multi-bank; refresh when due (drain then REF)  
- One DRAM command per cycle; bank timers run in parallel  
- Verilator directed TB (`make sim`)  
- 호스트 → 큐 → 뱅크별 FSM → 모델

```
rtl/     dram_pkg, host_if, dram_model, mem_ctrl, mem_ctrl_top
tb/      tb_mem_ctrl.sv, test_mem_ctrl.py
docs/    spec.md, scheduler-throughput.md, coverage.md
Makefile sim / lint / sim-cocotb
```

- Spec: [docs/spec.md](docs/spec.md)  
- Throughput / tradeoffs: [docs/scheduler-throughput.md](docs/scheduler-throughput.md)  
- Coverage vs gaps: [docs/coverage.md](docs/coverage.md)  

---

## Build & simulate / 빌드·시뮬

### Linux / WSL (recommended)

```bash
sudo apt update && sudo apt install -y verilator make build-essential
cd /mnt/d/mini-dram-controller   # if on D:\ under Windows
make check-tools
make sim
```

Optional cocotb: `pip install cocotb && make sim-cocotb`

### Native Windows

```powershell
wsl -e bash -lc "cd /mnt/d/mini-dram-controller && make sim"
```

Sim artifacts go to `obj_dir/` (gitignored). `sim/` is only a placeholder (`.gitkeep`).

---

## Roadmap / 로드맵

| Horizon | Focus |
|---------|--------|
| **Done** | Spec, queue+bank-parallel FSM, hit/miss/multi-bank/burst TB, throughput + coverage |
| **Next** | REF-under-load, waves CI, random/coverage bins, hit-prefer / auto-PRE experiments |
