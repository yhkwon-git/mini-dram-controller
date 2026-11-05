# Mini DRAM Controller — SystemVerilog RTL, directed and random testbenches
# Needs Verilator >= 5.0 (--binary, --timing). On Windows, run make inside WSL:
#   wsl make sim          (from the repository folder)
#
#   make sim              # directed testbench (tb/tb_mem_ctrl.sv) with the bound checkers
#   make sim WAVES=1      # same, and write tb_mem_ctrl.vcd
#   make sim-rand         # one random run: PATTERN=mixed SEED=1 N=2000
#   make regress          # random regression: every pattern x SEEDS seeds x N requests
#   make cov              # line / branch / toggle coverage of directed + random runs
#   make lint             # Verilator --lint-only on the RTL
#   make sim-cocotb       # optional cocotb smoke test (cocotb >= 2.0)
#   make clean

TOP_TB      ?= tb_mem_ctrl
BUILD_DIR   ?= obj_dir
RAND_DIR    ?= obj_dir_rand
WAVES       ?= 0

# make sim-rand / make regress / make cov
PATTERN     ?= mixed
SEED        ?= 1
N           ?= 2000
SEEDS       ?= 20
PATTERNS    ?= seq rowhit mixed rand hotbank stride
REGRESS_DIR ?= build/regress
COV_DIR     ?= build/cov
COV_SEEDS   ?= 1 2 3

RTL_SRCS := \
  rtl/dram_pkg.sv \
  rtl/host_if.sv \
  rtl/dram_model.sv \
  rtl/mem_ctrl.sv \
  rtl/mem_ctrl_top.sv

# Checkers bound into the RTL (tb/mc_bind.sv); every testbench build includes them
TB_CHECK := tb/dram_timing_checker.sv tb/host_if_checker.sv tb/mc_bind.sv
TB_SV    := tb/tb_mem_ctrl.sv
TB_RAND  := tb/mc_host_if.sv tb/mc_tb_pkg.sv tb/tb_mem_ctrl_rand.sv

VERILATOR ?= verilator
PYTHON    ?= python3
VFLAGS    := -Wall --timing --sv --binary -Wno-fatal --assert -Irtl
WAVE_FLAGS :=
ifeq ($(WAVES),1)
  WAVE_FLAGS := --trace +define+WAVES
endif

.PHONY: help sim rand-build sim-rand regress cov lint sim-cocotb clean check-tools check-verilator

help:
	@echo "Targets:"
	@echo "  make sim           - directed testbench with the bound checkers"
	@echo "  make sim WAVES=1   - same, and write tb_mem_ctrl.vcd"
	@echo "  make sim-rand      - one random run (PATTERN=$(PATTERN) SEED=$(SEED) N=$(N))"
	@echo "  make regress       - random regression ($(SEEDS) seeds x $(N) requests per pattern)"
	@echo "  make cov           - line / branch / toggle coverage, directed + random"
	@echo "  make lint          - Verilator lint-only on the RTL"
	@echo "  make sim-cocotb    - optional cocotb smoke test (cocotb >= 2.0)"
	@echo "  make check-tools   - print tool availability"
	@echo "  make clean"
	@echo ""
	@echo "Windows: install Verilator in WSL, then run 'wsl make sim' from this folder."

check-tools:
	@command -v $(VERILATOR) >/dev/null 2>&1 && $(VERILATOR) --version || echo "MISSING: verilator (>= 5.0)"
	@command -v $(PYTHON) >/dev/null 2>&1 && $(PYTHON) --version || echo "MISSING: python3"
	@$(PYTHON) -c "import cocotb; print('cocotb', cocotb.__version__)" 2>/dev/null || echo "MISSING: cocotb (optional)"

lint:
	$(VERILATOR) --lint-only --sv -Wall -Wno-fatal -Irtl $(RTL_SRCS)

sim: check-verilator
	$(VERILATOR) $(VFLAGS) $(WAVE_FLAGS) --Mdir $(BUILD_DIR) --top-module $(TOP_TB) \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_SV) -o sim_mem_ctrl
	$(BUILD_DIR)/sim_mem_ctrl

rand-build: check-verilator
	$(VERILATOR) $(VFLAGS) --Mdir $(RAND_DIR) --top-module tb_mem_ctrl_rand \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_RAND) -o sim_rand

sim-rand: rand-build
	$(RAND_DIR)/sim_rand +PATTERN=$(PATTERN) +SEED=$(SEED) +N=$(N)

regress: rand-build
	BIN=$(RAND_DIR)/sim_rand OUT=$(REGRESS_DIR) SEEDS=$(SEEDS) N=$(N) PATTERNS="$(PATTERNS)" \
	  bash tb/run_regress.sh
	$(PYTHON) tools/regress_report.py $(REGRESS_DIR)/regress.csv

# Coverage builds write one .dat per run. tools/cov_summary.py merges them by
# source point (the testbench hierarchy differs between the two tops) and
# prints the RTL modules only.
cov: check-verilator
	rm -rf $(COV_DIR)
	mkdir -p $(COV_DIR)
	$(VERILATOR) $(VFLAGS) --coverage --Mdir $(COV_DIR)/obj_dir --top-module $(TOP_TB) \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_SV) -o sim_cov > $(COV_DIR)/build.log 2>&1
	$(VERILATOR) $(VFLAGS) --coverage --Mdir $(COV_DIR)/obj_rand --top-module tb_mem_ctrl_rand \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_RAND) -o sim_rand_cov >> $(COV_DIR)/build.log 2>&1
	$(COV_DIR)/obj_dir/sim_cov +verilator+coverage+file+$(COV_DIR)/directed.dat > $(COV_DIR)/directed.log
	for p in $(PATTERNS); do for s in $(COV_SEEDS); do \
	  $(COV_DIR)/obj_rand/sim_rand_cov +PATTERN=$$p +SEED=$$s +N=$(N) \
	    +verilator+coverage+file+$(COV_DIR)/rand_$${p}_$$s.dat > $(COV_DIR)/rand_$${p}_$$s.log || exit 1; \
	done; done
	@echo "== directed only =="
	@$(PYTHON) tools/cov_summary.py $(COV_DIR)/directed.dat
	@echo "== directed + random =="
	@$(PYTHON) tools/cov_summary.py $(COV_DIR)/*.dat

check-verilator:
	@command -v $(VERILATOR) >/dev/null 2>&1 || { \
	  echo "ERROR: verilator not found (need >= 5.0 for --binary/--timing)."; \
	  echo "On Windows, install it in WSL and run: wsl make sim"; \
	  exit 1; \
	}

sim-cocotb: check-verilator
	@$(PYTHON) -c "import cocotb_tools.runner" 2>/dev/null || { \
	  echo "ERROR: cocotb >= 2.0 not found (pip install cocotb)"; \
	  exit 1; \
	}
	$(PYTHON) tb/cocotb_runner.py

clean:
	rm -rf $(BUILD_DIR) $(RAND_DIR) build sim_build results.xml coverage.dat *.vcd *.fst tb/__pycache__
