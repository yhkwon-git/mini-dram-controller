# Mini DRAM Controller + Simple DRAM Model

SystemVerilog mini DRAM memory controller with a simple synchronous DRAM model (own timing parameters, banks, open-page hit/miss).  
SystemVerilog 기반 미니 DRAM 메모리 컨트롤러 — 자체 타이밍 모델, 뱅크, 페이지 hit/miss.

| | |
|--|--|
| **Repo** | https://github.com/yhkwon-git/mini-dram-controller |
| **Status** | Skeleton + compile-smoke TB (scheduler TBD) |
| **License** | MIT |

---

## Overview / 구성

Host bus (`host_if`) → **mem_ctrl** timing FSM (ACT / RD / WR / PRE / REF) → sync **dram_model**.

- Latency knobs and open-row tracking in the model  
- Refresh slot + bank-conflict hooks (stubs for now)  
- Verilator smoke TB; optional cocotb  
- 호스트 버스 → 타이밍 FSM → DRAM 모델; Verilator / cocotb로 시뮬레이션

```
rtl/          dram_pkg, host_if, dram_model, mem_ctrl, mem_ctrl_top
tb/           tb_mem_ctrl.sv (SV smoke), test_mem_ctrl.py (cocotb stub)
docs/spec.md  timing params, address map, FSM states
Makefile      sim / lint / sim-cocotb
```

---

## Build & simulate / 빌드·시뮬

### Linux / WSL (recommended)

```bash
# Ubuntu example
sudo apt update && sudo apt install -y verilator make build-essential

cd /mnt/d/mini-dram-controller   # if cloned on D:\ under Windows
make check-tools
make lint      # optional
make sim       # Verilator build + idle smoke TB
```

Optional cocotb:

```bash
pip install cocotb
make sim-cocotb
```

### Native Windows

Use WSL for Verilator:

```powershell
wsl -e bash -lc "cd /mnt/d/mini-dram-controller && make sim"
```

---

## Roadmap / 로드맵

| Horizon | Focus |
|---------|--------|
| **~2 weeks** | Spec fill-in, enforce tRCD/tRP/tRAS in FSM, directed WR→RD + refresh tests, waves |
| **4–6 weeks** | Bank conflict + page hit/miss policy, throughput/latency note, coverage, 1p PPA |

Later artifacts: 1–2p spec · RTL · TB · waves/coverage note · 1p PPA.
