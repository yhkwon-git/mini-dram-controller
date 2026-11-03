# Mini DRAM Controller — SystemVerilog RTL + directed testbench
# Needs Verilator >= 5.0 (--binary, --timing). On Windows, run make inside WSL:
#   wsl make sim          (from the repository folder)
#
#   make sim              # Verilator build + run tb/tb_mem_ctrl.sv
#   make sim WAVES=1      # same, and write tb_mem_ctrl.vcd
#   make lint             # Verilator --lint-only on the RTL
#   make sim-cocotb       # optional cocotb smoke test (cocotb >= 2.0)
#   make clean

TOP_TB      ?= tb_mem_ctrl
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
PYTHON    ?= python3
VERILATOR_FLAGS := -Wall --timing --sv --binary -Wno-fatal
VERILATOR_FLAGS += -Irtl --Mdir $(BUILD_DIR)
ifeq ($(WAVES),1)
  VERILATOR_FLAGS += --trace +define+WAVES
endif

.PHONY: help sim lint sim-cocotb clean check-tools check-verilator

help:
	@echo "Targets:"
	@echo "  make sim           - Verilator build + run tb/tb_mem_ctrl.sv"
	@echo "  make sim WAVES=1   - same, and write tb_mem_ctrl.vcd"
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
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP_TB) \
	  $(RTL_SRCS) $(TB_SV) -o sim_mem_ctrl
	$(BUILD_DIR)/sim_mem_ctrl

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
	rm -rf $(BUILD_DIR) sim_build results.xml *.vcd *.fst tb/__pycache__
