# Mini DRAM Controller — educational skeleton
# Prefer WSL/Linux with Verilator. Native Windows: use WSL path below.
#
#   make sim          # Verilator compile + run SV smoke TB
#   make lint         # Verilator --lint-only
#   make sim-cocotb   # optional cocotb (needs cocotb + Verilator)
#   make clean

TOP_TB      ?= tb_mem_ctrl
TOP_DUT     ?= mem_ctrl_top
BUILD_DIR   ?= obj_dir
WAVES       ?= 0

RTL_SRCS := \
  rtl/dram_pkg.sv \
  rtl/host_if.sv \
  rtl/dram_model.sv \
  rtl/mem_ctrl.sv \
  rtl/mem_ctrl_top.sv

TB_SV := tb/tb_mem_ctrl.sv

VERILATOR ?= verilator
VERILATOR_FLAGS := -Wall --timing --sv --binary -Wno-fatal
VERILATOR_FLAGS += -Irtl
ifeq ($(WAVES),1)
  VERILATOR_FLAGS += --trace
endif

.PHONY: help sim lint sim-cocotb clean check-tools

help:
	@echo "Targets:"
	@echo "  make sim         - Verilator build+run SV smoke TB"
	@echo "  make lint        - Verilator lint-only"
	@echo "  make sim-cocotb  - cocotb smoke (WSL/Linux)"
	@echo "  make check-tools - print tool availability"
	@echo "  make clean"
	@echo ""
	@echo "Windows note: install Verilator in WSL, then:"
	@echo "  wsl -e bash -lc 'cd /mnt/d/mini-dram-controller && make sim'"

check-tools:
	@command -v $(VERILATOR) >/dev/null 2>&1 && $(VERILATOR) --version || echo "MISSING: verilator"
	@command -v python3 >/dev/null 2>&1 && python3 --version || echo "MISSING: python3"
	@python3 -c "import cocotb; print('cocotb', cocotb.__version__)" 2>/dev/null || echo "MISSING: cocotb (optional)"

lint:
	$(VERILATOR) --lint-only --sv -Wall -Wno-fatal -Irtl $(RTL_SRCS)

sim: check-verilator
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP_TB) \
	  $(RTL_SRCS) $(TB_SV) -o sim_mem_ctrl
	./$(BUILD_DIR)/sim_mem_ctrl

check-verilator:
	@command -v $(VERILATOR) >/dev/null 2>&1 || { \
	  echo "ERROR: verilator not found."; \
	  echo "On Windows, use WSL:"; \
	  echo "  wsl -e bash -lc 'cd /mnt/d/mini-dram-controller && make sim'"; \
	  echo "Install: sudo apt install verilator  (or build from source)"; \
	  exit 1; \
	}

# cocotb runner (optional)
SIM             ?= verilator
MODULE          ?= test_mem_ctrl
TOPLEVEL        ?= $(TOP_DUT)
TOPLEVEL_LANG   ?= verilog
VERILOG_SOURCES ?= $(abspath $(RTL_SRCS))
export SIM MODULE TOPLEVEL TOPLEVEL_LANG VERILOG_SOURCES
export PYTHONPATH := $(abspath tb):$(PYTHONPATH)

sim-cocotb: check-verilator
	@python3 -c "import cocotb" 2>/dev/null || { echo "ERROR: pip install cocotb"; exit 1; }
	cd tb && python3 -m cocotb_tools.runner 2>/dev/null || \
	  $(MAKE) -C tb -f Makefile.cocotb || \
	  echo "TIP: from WSL, 'pip install cocotb' then re-run make sim-cocotb"

clean:
	rm -rf $(BUILD_DIR) sim_build results.xml *.vcd *.fst
	rm -rf tb/sim_build tb/results.xml
