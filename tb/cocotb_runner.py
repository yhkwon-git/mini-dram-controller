"""Build mem_ctrl_top with Verilator and run the cocotb tests in test_mem_ctrl.py.

    make sim-cocotb        # needs cocotb >= 2.0

Exits non-zero when a test fails or no test ran, so make reports the failure.
"""

import sys
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

ROOT = Path(__file__).resolve().parent.parent
RTL = ["dram_pkg.sv", "host_if.sv", "dram_model.sv", "mc_queue.sv", "mc_bank.sv",
       "mc_chan.sv", "mc_refresh.sv", "mc_sched.sv", "mc_resp.sv", "mem_ctrl.sv",
       "mem_ctrl_top.sv"]
BUILD_DIR = ROOT / "sim_build"
TOPLEVEL = "mem_ctrl_top"


def main() -> int:
    runner = get_runner("verilator")
    runner.build(
        sources=[ROOT / "rtl" / name for name in RTL],
        includes=[ROOT / "rtl"],
        hdl_toplevel=TOPLEVEL,
        build_dir=BUILD_DIR,
        always=True,
    )
    results_xml = runner.test(
        test_module="test_mem_ctrl",
        hdl_toplevel=TOPLEVEL,
        build_dir=BUILD_DIR,
        test_dir=ROOT / "tb",
    )
    total, failed = get_results(results_xml)
    print(f"cocotb: {total - failed}/{total} test(s) passed")
    return 1 if failed or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
