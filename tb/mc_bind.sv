// The checkers attach to the RTL through bind, so neither the RTL nor a
// testbench instantiates them. Every testbench build compiles this file.
//   dut.u_dram.u_tchk  DRAM command timing and protocol (dram_timing_checker)
//   dut.u_hchk         host valid/ready rules (host_if_checker)
`timescale 1ns/1ps

bind dram_model   dram_timing_checker u_tchk (.*);
bind mem_ctrl_top host_if_checker     u_hchk (.*);
