// Directed smoke: WR then RD (ACT→WR, page-hit RD) via mem_ctrl_top.
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

  int unsigned errs;

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
    .rsp_err(rsp_err)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  function automatic logic [ADDR_BITS-1:0] make_addr(
    input logic [$clog2(NUM_BANKS)-1:0] b,
    input logic [ROW_BITS-1:0] r,
    input logic [COL_BITS-1:0] c
  );
    return {b, r, c};
  endfunction

  task automatic host_write(
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
    @(posedge clk);
    while (rsp_valid !== 1'b1)
      @(posedge clk);
    @(negedge clk);
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

  logic [DATA_BITS-1:0] rdata;
  logic [ADDR_BITS-1:0] a0;

  initial begin
    errs      = 0;
    rst_n     = 1'b0;
    req_valid = 1'b0;
    req_write = 1'b0;
    req_addr  = '0;
    req_wdata = '0;
    rsp_ready = 1'b1;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    a0 = make_addr(2'b00, 8'h11, 4'hA);

    $display("[TB] WR bank0 row=0x11 col=0xA data=0xA5A5_5A5A");
    host_write(a0, 32'hA5A5_5A5A);

    $display("[TB] RD same address (expect page hit)");
    host_read(a0, rdata);
    if (rdata !== 32'hA5A5_5A5A) begin
      $error("[TB] RD mismatch got=0x%08h", rdata);
      errs++;
    end else begin
      $display("[TB] RD OK data=0x%08h", rdata);
    end

    repeat (8) @(posedge clk);

    if (errs == 0)
      $display("[TB] PASS — ACT/WR + hit RD path OK");
    else
      $error("[TB] FAIL — %0d error(s)", errs);

    $finish;
  end

  initial begin
    #200_000;
    $error("[TB] timeout");
    $finish;
  end

endmodule
