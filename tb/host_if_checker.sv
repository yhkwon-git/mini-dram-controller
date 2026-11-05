// Valid/ready rules on the host port. tb/mc_bind.sv binds one instance into
// mem_ctrl_top.
//
// a_req_* say what the host (the testbench) must do; the controller may rely
// on them. a_rsp_* and a_known say what the controller must do. The c_* cover
// points mark handshake corners the regression has to reach (make cov).
`timescale 1ns/1ps

module host_if_checker
  import dram_pkg::*;
(
  input logic                 clk,
  input logic                 rst_n,
  input logic                 req_valid,
  input logic                 req_ready,
  input logic                 req_write,
  input logic [ADDR_BITS-1:0] req_addr,
  input logic [DATA_BITS-1:0] req_wdata,
  input logic                 rsp_valid,
  input logic                 rsp_ready,
  input logic [DATA_BITS-1:0] rsp_rdata,
  input logic                 rsp_err
);

  int unsigned dut_violations;   // the controller broke a rule
  int unsigned host_violations;  // the testbench broke a rule
  bit          asserts_on;

  initial begin
    dut_violations  = 0;
    host_violations = 0;
    // Runs its action only when the build enables assertions (--assert).
    asserts_on = 1'b0;
    a_probe: assert (1'b0) else asserts_on = 1'b1;
  end

  // Host: keep the request and its payload until the controller takes it.
  a_req_hold: assert property (@(posedge clk) disable iff (!rst_n)
      req_valid && !req_ready |=> req_valid && $stable({req_write, req_addr, req_wdata}))
    else begin
      host_violations++;
      $display("[HCHK] VIOLATION a_req_hold at %0t: request dropped or changed before req_ready", $time);
    end

  // Controller: keep the response and its data until the host takes it.
  a_rsp_hold: assert property (@(posedge clk) disable iff (!rst_n)
      rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp_rdata))
    else begin
      dut_violations++;
      $display("[HCHK] VIOLATION a_rsp_hold at %0t: response dropped or changed before rsp_ready", $time);
    end

  // Controller: handshake outputs are never X/Z after reset (4-state simulators).
  a_known: assert property (@(posedge clk) disable iff (!rst_n)
      !$isunknown({req_ready, rsp_valid}) && (!rsp_valid || !$isunknown({rsp_rdata, rsp_err})))
    else begin
      dut_violations++;
      $display("[HCHK] VIOLATION a_known at %0t: X/Z on a handshake output", $time);
    end

  // Controller: v1 never reports an error (rsp_err is reserved).
  a_rsp_err: assert property (@(posedge clk) disable iff (!rst_n) rsp_valid |-> !rsp_err)
    else begin
      dut_violations++;
      $display("[HCHK] VIOLATION a_rsp_err at %0t: rsp_err set", $time);
    end

  c_req_stall:    cover property (@(posedge clk) disable iff (!rst_n) req_valid && !req_ready);
  c_req_b2b:      cover property (@(posedge clk) disable iff (!rst_n) (req_valid && req_ready) [*2]);
  c_rsp_stall:    cover property (@(posedge clk) disable iff (!rst_n) rsp_valid && !rsp_ready);
  c_rsp_stall_16: cover property (@(posedge clk) disable iff (!rst_n) (rsp_valid && !rsp_ready) [*16]);
  c_rsp_b2b_4:    cover property (@(posedge clk) disable iff (!rst_n) (rsp_valid && rsp_ready) [*4]);

  function automatic void report();
    if (!asserts_on) begin
      dut_violations++;
      $display("[HCHK] ERROR assertions are off; build with --assert");
    end
    $display("[HCHK] %s: controller violations %0d, host violations %0d",
             (dut_violations + host_violations == 0) ? "PASS" : "FAIL",
             dut_violations, host_violations);
  endfunction

endmodule
