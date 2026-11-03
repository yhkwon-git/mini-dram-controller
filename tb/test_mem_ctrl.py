"""
cocotb smoke test for mem_ctrl_top — an optional path next to the SV testbench.

    make sim-cocotb        # needs cocotb >= 2.0 and Verilator

Functional coverage (hit / miss / multi-bank / burst / back-pressure) lives in
tb/tb_mem_ctrl.sv and runs with `make sim`.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_reset_idle(dut):
    """After reset the controller is ready, no response is pending, banks are closed."""
    Clock(dut.clk, 10, unit="ns").start()

    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.req_write.value = 0
    dut.req_addr.value = 0
    dut.req_wdata.value = 0
    dut.rsp_ready.value = 1

    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 20)

    assert dut.req_ready.value == 1, "req_ready should be 1 after reset"
    assert dut.rsp_valid.value == 0, "no response may be pending after reset"
    assert dut.dram_bank_open.value == 0, "all banks start closed"
