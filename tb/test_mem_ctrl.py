"""
Optional cocotb smoke (when cocotb + Verilator available under WSL/Linux).

    make sim-cocotb

Functional host RD/WR coverage is TODO until the scheduler is implemented.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


@cocotb.test()
async def test_reset_idle(dut):
    """Reset then idle for a few cycles — compile/run smoke only."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.req_write.value = 0
    dut.req_addr.value = 0
    dut.req_wdata.value = 0
    dut.rsp_ready.value = 1

    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 20)

    assert int(dut.rst_n.value) == 1
    dut._log.info("cocotb smoke OK — idle complete (functional tests TODO)")
