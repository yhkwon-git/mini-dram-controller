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

# Controller build variants that the regression and coverage also run, so the
# code behind each parameter is exercised: name:-Gflag[,-Gflag...]
VARIANTS      ?= fcfs:-GP_FR_FCFS=0 starve24:-GP_STARVE_LIMIT=24 rdpipe1:-GP_RD_PIPE=1 depth4:-GP_DEPTH=4 \
                 nodrain:-GP_WDRAIN=0 fcfs_nodrain:-GP_FR_FCFS=0,-GP_WDRAIN=0 \
                 close:-GP_PAGE_POLICY=1 timer:-GP_PAGE_POLICY=2 \
                 map_brc:-GP_ADDR_MAP=0 map_rbc:-GP_ADDR_MAP=1 map_rcb:-GP_ADDR_MAP=2
VARIANT_SEEDS ?= 10

# Builds and runs go JOBS at a time (make regress JOBS=1 for one at a time)
JOBS          ?= $(shell nproc 2>/dev/null || echo 1)
comma         := ,
VARIANT_NAMES := $(foreach v,$(VARIANTS),$(firstword $(subst :, ,$(v))))
variant_flags  = $(subst $(comma), ,$(patsubst $(1):%,%,$(filter $(1):%,$(VARIANTS))))

RTL_SRCS := \
  rtl/dram_pkg.sv \
  rtl/host_if.sv \
  rtl/dram_model.sv \
  rtl/mc_queue.sv \
  rtl/mc_xage.sv \
  rtl/mc_wdrain.sv \
  rtl/mc_bank.sv \
  rtl/mc_chan.sv \
  rtl/mc_refresh.sv \
  rtl/mc_sched.sv \
  rtl/mc_resp.sv \
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

.PHONY: help sim rand-build rand-build-quiet rand-variants sim-rand regress cov ppa lint sim-cocotb clean \
        check-tools check-verilator cov-build-directed

help:
	@echo "Targets:"
	@echo "  make sim           - directed testbench with the bound checkers"
	@echo "  make sim WAVES=1   - same, and write tb_mem_ctrl.vcd"
	@echo "  make sim-rand      - one random run (PATTERN=$(PATTERN) SEED=$(SEED) N=$(N))"
	@echo "  make regress       - random regression ($(SEEDS) seeds x $(N) requests per pattern, plus variants)"
	@echo "  make cov           - line / branch / toggle coverage, directed + random"
	@echo "  make ppa           - area and timing of mem_ctrl (sv2v, Yosys, Nangate45, OpenSTA)"
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

# One build per variant; make -j builds them in parallel (regress does)
rand-variants: $(addprefix rand-variant-,$(VARIANT_NAMES))

rand-variant-%: check-verilator
	@mkdir -p $(RAND_DIR)_$*
	@echo "building variant $* ($(call variant_flags,$*))"
	@$(VERILATOR) $(VFLAGS) --Mdir $(RAND_DIR)_$* --top-module tb_mem_ctrl_rand $(call variant_flags,$*) \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_RAND) -o sim_rand > $(RAND_DIR)_$*/build.log 2>&1 \
	  || { cat $(RAND_DIR)_$*/build.log; exit 1; }

rand-build-quiet: check-verilator
	@mkdir -p $(RAND_DIR)
	@echo "building default"
	@$(VERILATOR) $(VFLAGS) --Mdir $(RAND_DIR) --top-module tb_mem_ctrl_rand \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_RAND) -o sim_rand > $(RAND_DIR)/build.log 2>&1 \
	  || { cat $(RAND_DIR)/build.log; exit 1; }

regress: check-verilator
	@$(MAKE) --no-print-directory -j$(JOBS) rand-build-quiet rand-variants
	RUNS="default=$(RAND_DIR)/sim_rand:$(SEEDS) $(foreach n,$(VARIANT_NAMES),$(n)=$(RAND_DIR)_$(n)/sim_rand:$(VARIANT_SEEDS))" \
	  OUT=$(REGRESS_DIR) N=$(N) PATTERNS="$(PATTERNS)" JOBS=$(JOBS) bash tb/run_regress.sh
	$(PYTHON) tools/regress_report.py $(REGRESS_DIR)/regress.csv

# Coverage builds write one .dat per run. tools/cov_summary.py merges them by
# source point (the testbench hierarchy differs between the two tops) and
# prints the RTL modules only. Builds and runs go JOBS at a time.
cov-build-directed: check-verilator
	@echo "coverage build directed"
	@$(VERILATOR) $(VFLAGS) --coverage --Mdir $(COV_DIR)/obj_directed --top-module $(TOP_TB) \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_SV) -o sim > $(COV_DIR)/build_directed.log 2>&1 \
	  || { cat $(COV_DIR)/build_directed.log; exit 1; }

cov-build-%: check-verilator
	@echo "coverage build $* ($(call variant_flags,$*))"
	@$(VERILATOR) $(VFLAGS) --coverage --Mdir $(COV_DIR)/obj_$* --top-module tb_mem_ctrl_rand $(call variant_flags,$*) \
	  $(RTL_SRCS) $(TB_CHECK) $(TB_RAND) -o sim > $(COV_DIR)/build_$*.log 2>&1 \
	  || { cat $(COV_DIR)/build_$*.log; exit 1; }

cov: check-verilator
	rm -rf $(COV_DIR)
	mkdir -p $(COV_DIR)
	@$(MAKE) --no-print-directory -j$(JOBS) cov-build-directed $(addprefix cov-build-,default $(VARIANT_NAMES))
	$(COV_DIR)/obj_directed/sim +verilator+coverage+file+$(COV_DIR)/directed.dat > $(COV_DIR)/directed.log
	@for n in default $(VARIANT_NAMES); do \
	  seeds="$(COV_SEEDS)"; [ "$$n" = default ] || seeds=1; \
	  for p in $(PATTERNS); do for s in $$seeds; do echo "$$n $$p $$s"; done; done; \
	done | xargs -P $(JOBS) -L 1 sh -c '$(COV_DIR)/obj_$$0/sim +CONFIG=$$0 +PATTERN=$$1 +SEED=$$2 +N=$(N) \
	  +verilator+coverage+file+$(COV_DIR)/rand_$$0_$$1_$$2.dat > $(COV_DIR)/rand_$$0_$$1_$$2.log \
	  || { echo "FAIL coverage run $$0 $$1 $$2"; exit 255; }'
	@echo "== directed only =="
	@$(PYTHON) tools/cov_summary.py $(COV_DIR)/directed.dat
	@echo "== directed + random (default build and variants) =="
	@$(PYTHON) tools/cov_summary.py $(COV_DIR)/*.dat

# Area and timing: sv2v -> Yosys (Nangate45 typical) -> OpenSTA. Set SV2V and LIB
# if the tools are not where syn/ppa.sh expects them.
ppa:
	OUT=build/ppa bash syn/ppa.sh

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
