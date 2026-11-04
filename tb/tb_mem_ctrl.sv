// Directed tests: hit/miss/multi-bank, 4-bank burst, response back-pressure.
// A failed check prints "[TB] ERROR ..." and the run continues; the end of the
// run prints the summary and calls $fatal, so any simulator exits non-zero.
// ($error would stop Verilator at the first failure, before the summary, and
// $error + $finish exits 0 on simulators that do not stop on $error.)
`timescale 1ns/1ps

module tb_mem_ctrl
  import dram_pkg::*;
;

  logic clk;
  logic rst_n;

  logic                 req_valid, req_ready, req_write;
  logic [ADDR_BITS-1:0] req_addr;
  logic [DATA_BITS-1:0] req_wdata;
  logic                 rsp_valid, rsp_ready, rsp_err;
  logic [DATA_BITS-1:0] rsp_rdata;

  logic                 dram_page_hit, dram_access_err;
  logic [NUM_BANKS-1:0] dram_bank_open;

  int unsigned errs;
  int unsigned access_err_count;
  int unsigned rsp_err_count;      // rsp_err pulses on accepted responses (v1: must stay 0)
  int unsigned ref_count;          // CMD_REF issued to the model
  int unsigned max_engines_active; // scenario 4: bank engines outside ST_IDLE at once

  mem_ctrl_top dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_write(req_write),
    .req_addr(req_addr),
    .req_wdata(req_wdata),
    .rsp_valid(rsp_valid),
    .rsp_ready(rsp_ready),
    .rsp_rdata(rsp_rdata),
    .rsp_err(rsp_err),
    .dram_page_hit(dram_page_hit),
    .dram_access_err(dram_access_err),
    .dram_bank_open(dram_bank_open)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

`ifdef WAVES
  // make sim WAVES=1 -> tb_mem_ctrl.vcd in the directory make runs from
  initial begin
    $dumpfile("tb_mem_ctrl.vcd");
    $dumpvars(0, tb_mem_ctrl);
  end
`endif

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      access_err_count <= 0;
      rsp_err_count    <= 0;
      ref_count        <= 0;
    end else begin
      if (dram_access_err)                    access_err_count <= access_err_count + 1;
      if (rsp_valid && rsp_ready && rsp_err)  rsp_err_count    <= rsp_err_count + 1;
      if (dut.d_cmd == CMD_REF)               ref_count        <= ref_count + 1;
    end
  end

  function automatic logic [ADDR_BITS-1:0] make_addr(
    input logic [$clog2(NUM_BANKS)-1:0] b,
    input logic [ROW_BITS-1:0] r,
    input logic [COL_BITS-1:0] c
  );
    return {b, r, c};
  endfunction

  // White-box probe: how many bank engines are busy right now.
  function automatic int unsigned engines_active();
    engines_active = 0;
    if (dut.u_ctrl.b_state[0] != ST_IDLE) engines_active++;
    if (dut.u_ctrl.b_state[1] != ST_IDLE) engines_active++;
    if (dut.u_ctrl.b_state[2] != ST_IDLE) engines_active++;
    if (dut.u_ctrl.b_state[3] != ST_IDLE) engines_active++;
  endfunction

  // Drive one request and return once it is accepted (no wait for the response).
  task automatic host_accept(
    input logic                 write,
    input logic [ADDR_BITS-1:0] addr,
    input logic [DATA_BITS-1:0] data
  );
    @(negedge clk);
    req_valid = 1'b1;
    req_write = write;
    req_addr  = addr;
    req_wdata = data;
    @(posedge clk);
    while (req_ready !== 1'b1)
      @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
  endtask

  task automatic host_accept_write(
    input logic [ADDR_BITS-1:0] addr,
    input logic [DATA_BITS-1:0] data
  );
    host_accept(1'b1, addr, data);
  endtask

  task automatic host_wait_rsp();
    @(posedge clk);
    while (rsp_valid !== 1'b1)
      @(posedge clk);
    @(negedge clk);
  endtask

  task automatic host_write(
    input logic [ADDR_BITS-1:0] addr,
    input logic [DATA_BITS-1:0] data
  );
    host_accept_write(addr, data);
    host_wait_rsp();
  endtask

  task automatic host_read(
    input  logic [ADDR_BITS-1:0] addr,
    output logic [DATA_BITS-1:0] data
  );
    host_accept(1'b0, addr, '0);
    @(posedge clk);
    while (rsp_valid !== 1'b1)
      @(posedge clk);
    data = rsp_rdata;
    @(negedge clk);
  endtask

  task automatic check_eq(
    input string                tag,
    input logic [DATA_BITS-1:0] got,
    input logic [DATA_BITS-1:0] exp
  );
    if (got !== exp) begin
      $display("[TB] ERROR %s mismatch got=0x%08h exp=0x%08h", tag, got, exp);
      errs++;
    end else
      $display("[TB] %s OK (0x%08h)", tag, got);
  endtask

  logic [DATA_BITS-1:0] rdata;
  logic [ADDR_BITS-1:0] a_b0_r1, a_b0_r2, a_b1_r3, a_b0_r4;
  logic [ADDR_BITS-1:0] a_b2, a_b3;

  // Scenario 5: more reads than response tags (16) while rsp_ready is low
  localparam int BP_N    = 20;
  localparam int BP_HOLD = 150;  // cycles with rsp_ready = 0
  logic [ADDR_BITS-1:0] bp_addr [BP_N];
  logic [DATA_BITS-1:0] bp_data [BP_N];
  int unsigned          bp_got, bp_bad, bp_ref0;

  initial begin
    errs               = 0;
    max_engines_active = 0;
    rst_n              = 1'b0;
    req_valid          = 1'b0;
    req_write          = 1'b0;
    req_addr           = '0;
    req_wdata          = '0;
    rsp_ready          = 1'b1;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    a_b0_r1 = make_addr(2'd0, 8'h11, 4'hA);
    a_b0_r2 = make_addr(2'd0, 8'h22, 4'h5);
    a_b1_r3 = make_addr(2'd1, 8'h33, 4'h3);
    a_b0_r4 = make_addr(2'd0, 8'h44, 4'h1);
    a_b2    = make_addr(2'd2, 8'h55, 4'h2);
    a_b3    = make_addr(2'd3, 8'h66, 4'h3);

    $display("[TB] === SCENARIO 1: page hit WR→RD ===");
    host_write(a_b0_r1, 32'hA5A5_5A5A);
    host_read(a_b0_r1, rdata);
    check_eq("hit RD", rdata, 32'hA5A5_5A5A);

    $display("[TB] === SCENARIO 2: page miss (bank0 row change) ===");
    host_write(a_b0_r2, 32'hBEEF_0002);
    host_read(a_b0_r2, rdata);
    check_eq("miss-new RD", rdata, 32'hBEEF_0002);
    host_read(a_b0_r1, rdata);
    check_eq("miss-old RD", rdata, 32'hA5A5_5A5A);

    $display("[TB] === SCENARIO 3: multi-bank + bank0 conflict ===");
    host_write(a_b1_r3, 32'hC0DE_0001);
    host_read(a_b1_r3, rdata);
    check_eq("bank1 RD", rdata, 32'hC0DE_0001);
    host_write(a_b0_r4, 32'hD00D_0004);
    host_read(a_b0_r4, rdata);
    check_eq("bank0 conflict RD", rdata, 32'hD00D_0004);
    host_read(a_b1_r3, rdata);
    check_eq("bank1 survived", rdata, 32'hC0DE_0001);

    // ------------------------------------------------------------------
    $display("[TB] === SCENARIO 4: 4-bank write burst (bank engines in parallel) ===");
    // Accept back to back without waiting for responses (rsp_ready=1 drains
    // them). Open-page banks stay open after a serial schedule too, so the
    // check counts bank engines that are busy at the same time instead.
    fork
      begin : observe
        repeat (60) begin
          @(posedge clk);
          if (engines_active() > max_engines_active)
            max_engines_active = engines_active();
        end
      end
      begin : burst
        host_accept_write(make_addr(2'd0, 8'h10, 4'h0), 32'h1000_0000);
        host_accept_write(make_addr(2'd1, 8'h20, 4'h0), 32'h2000_0000);
        host_accept_write(a_b2, 32'h3000_0000);
        host_accept_write(a_b3, 32'h4000_0000);
      end
    join
    // Drain any remaining write responses
    repeat (80) @(posedge clk);
    $display("[TB] peak bank engines active at once=%0d", max_engines_active);
    if (max_engines_active < 2) begin
      $display("[TB] ERROR expected >=2 bank engines active at once during the burst");
      errs++;
    end
    host_read(make_addr(2'd0, 8'h10, 4'h0), rdata);
    check_eq("q bank0", rdata, 32'h1000_0000);
    host_read(make_addr(2'd1, 8'h20, 4'h0), rdata);
    check_eq("q bank1", rdata, 32'h2000_0000);
    host_read(a_b2, rdata);
    check_eq("q bank2", rdata, 32'h3000_0000);
    host_read(a_b3, rdata);
    check_eq("q bank3", rdata, 32'h4000_0000);

    // ------------------------------------------------------------------
    $display("[TB] === SCENARIO 5: response back-pressure (%0d reads, rsp_ready low %0d cycles) ===",
             BP_N, BP_HOLD);
    // More reads than response tags are in flight: the controller has to stop
    // accepting instead of reusing a tag whose response is still buffered.
    for (int i = 0; i < BP_N; i++) begin
      bp_addr[i] = make_addr(i[1:0], 8'h80 + 8'(i / NUM_BANKS), 4'(i));
      bp_data[i] = 32'h5000_0000 + 32'(i);
      host_write(bp_addr[i], bp_data[i]);
    end
    bp_got  = 0;
    bp_bad  = 0;
    bp_ref0 = ref_count;
    @(negedge clk);
    rsp_ready = 1'b0;
    fork
      begin : bp_issue
        for (int i = 0; i < BP_N; i++)
          host_accept(1'b0, bp_addr[i], '0);
      end
      begin : bp_drain
        repeat (BP_HOLD) @(posedge clk);
        @(negedge clk);
        rsp_ready = 1'b1;
        for (int cyc = 0; cyc < 1000 && bp_got < BP_N; cyc++) begin
          @(posedge clk);
          if (rsp_valid === 1'b1) begin
            if (rsp_rdata !== bp_data[bp_got]) begin
              $display("[TB] ERROR bp rd%0d mismatch got=0x%08h exp=0x%08h",
                       bp_got, rsp_rdata, bp_data[bp_got]);
              bp_bad++;
            end
            bp_got++;
          end
        end
      end
    join
    repeat (40) @(posedge clk);
    if (rsp_valid === 1'b1) begin
      $display("[TB] ERROR bp: unexpected extra response");
      bp_bad++;
    end
    if (bp_got != BP_N) begin
      $display("[TB] ERROR bp: got %0d of %0d responses", bp_got, BP_N);
      bp_bad++;
    end
    if (ref_count == bp_ref0) begin
      $display("[TB] ERROR bp: no refresh during the back-pressure test");
      bp_bad++;
    end
    if (bp_bad == 0)
      $display("[TB] back-pressure OK (%0d/%0d in order, %0d REF during the test)",
               bp_got, BP_N, ref_count - bp_ref0);
    errs += bp_bad;

    repeat (4) @(posedge clk);

    if (access_err_count != 0) begin
      $display("[TB] ERROR access_err count=%0d", access_err_count);
      errs++;
    end else
      $display("[TB] access_err count=0 OK");

    if (rsp_err_count != 0) begin
      $display("[TB] ERROR rsp_err count=%0d", rsp_err_count);
      errs++;
    end else
      $display("[TB] rsp_err count=0 OK");

    // Model observability outputs must not be X/Z at the end of the run
    if ($isunknown({dram_page_hit, dram_bank_open})) begin
      $display("[TB] ERROR X/Z on model observability outputs");
      errs++;
    end

    if (errs == 0) begin
      $display("[TB] PASS — hit/miss/multi-bank/burst/back-pressure OK");
      $finish;
    end else begin
      $fatal(1, "[TB] FAIL — %0d error(s)", errs);
    end
  end

  initial begin
    #1_000_000;
    $fatal(1, "[TB] timeout");
  end

endmodule
