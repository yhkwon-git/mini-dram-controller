// Directed tests: hit/miss/multi-bank + queued multi-bank parallel accepts.
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
  int unsigned max_bank_active; // coarse: how many banks non-idle observed via open mask during queue test

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

  always_ff @(posedge clk) begin
    if (!rst_n)
      access_err_count <= 0;
    else if (dram_access_err)
      access_err_count <= access_err_count + 1;
  end

  // Cheap assertions
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (rsp_valid && rsp_err)
        $error("[TB] unexpected rsp_err");
    end
  end

  function automatic logic [ADDR_BITS-1:0] make_addr(
    input logic [$clog2(NUM_BANKS)-1:0] b,
    input logic [ROW_BITS-1:0] r,
    input logic [COL_BITS-1:0] c
  );
    return {b, r, c};
  endfunction

  task automatic host_accept_write(
    input logic [ADDR_BITS-1:0] addr,
    input logic [DATA_BITS-1:0] data
  );
    @(negedge clk);
    req_valid = 1'b1;
    req_write = 1'b1;
    req_addr  = addr;
    req_wdata = data;
    @(posedge clk);
    while (req_ready !== 1'b1)
      @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
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
    @(negedge clk);
    req_valid = 1'b1;
    req_write = 1'b0;
    req_addr  = addr;
    req_wdata = '0;
    @(posedge clk);
    while (req_ready !== 1'b1)
      @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
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
      $error("[TB] %s mismatch got=0x%08h exp=0x%08h", tag, got, exp);
      errs++;
    end else
      $display("[TB] %s OK (0x%08h)", tag, got);
  endtask

  logic [DATA_BITS-1:0] rdata;
  logic [ADDR_BITS-1:0] a_b0_r1, a_b0_r2, a_b1_r3, a_b0_r4;
  logic [ADDR_BITS-1:0] a_b2, a_b3;
  int unsigned open_pop;

  initial begin
    errs             = 0;
    access_err_count = 0;
    max_bank_active  = 0;
    rst_n            = 1'b0;
    req_valid        = 1'b0;
    req_write        = 1'b0;
    req_addr         = '0;
    req_wdata        = '0;
    rsp_ready        = 1'b1;

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
    $display("[TB] === SCENARIO 4: queue depth — burst accept 4 banks ===");
    // Keep rsp_ready=1 so completions drain; verify via subsequent RDs.
    // Accept as fast as req_ready allows (queue absorbs; banks run in parallel).
    fork
      begin : observe
        repeat (60) begin
          @(posedge clk);
          open_pop = int'(dram_bank_open[0]) + int'(dram_bank_open[1]) +
                     int'(dram_bank_open[2]) + int'(dram_bank_open[3]);
          if (open_pop > max_bank_active) max_bank_active = open_pop;
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
    $display("[TB] peak banks open during burst=%0d", max_bank_active);
    if (max_bank_active < 2) begin
      $error("[TB] expected >=2 banks open during parallel burst");
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

    repeat (4) @(posedge clk);

    if (access_err_count != 0) begin
      $error("[TB] access_err count=%0d", access_err_count);
      errs++;
    end else
      $display("[TB] access_err count=0 OK");

    // Silence unused
    if (dram_page_hit !== 1'b0 && dram_page_hit !== 1'b1) errs++;

    if (errs == 0)
      $display("[TB] PASS — hit/miss/multi-bank/queue-parallel OK");
    else
      $error("[TB] FAIL — %0d error(s)", errs);

    $finish;
  end

  initial begin
    #1_000_000;
    $error("[TB] timeout");
    $finish;
  end

endmodule
