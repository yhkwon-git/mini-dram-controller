// Directed tests: page hit, page miss (same-bank row conflict), multi-bank + miss.
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
    if (rst_n && dram_access_err)
      access_err_count <= access_err_count + 1;
  end

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

  task automatic check_eq(
    input string                 tag,
    input logic [DATA_BITS-1:0]  got,
    input logic [DATA_BITS-1:0]  exp
  );
    if (got !== exp) begin
      $error("[TB] %s mismatch got=0x%08h exp=0x%08h", tag, got, exp);
      errs++;
    end else begin
      $display("[TB] %s OK (0x%08h)", tag, got);
    end
  endtask

  logic [DATA_BITS-1:0] rdata;
  logic [ADDR_BITS-1:0] a_b0_r1, a_b0_r2, a_b1_r3, a_b0_r4;

  initial begin
    errs             = 0;
    access_err_count = 0;
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
    a_b0_r2 = make_addr(2'd0, 8'h22, 4'h5); // same bank, different row → page miss
    a_b1_r3 = make_addr(2'd1, 8'h33, 4'h3); // other bank
    a_b0_r4 = make_addr(2'd0, 8'h44, 4'h1); // bank0 row conflict again

    // ------------------------------------------------------------------
    // 1) Page hit: ACT→WR then RD same bank/row
    // ------------------------------------------------------------------
    $display("[TB] === SCENARIO 1: page hit WR→RD ===");
    host_write(a_b0_r1, 32'hA5A5_5A5A);
    host_read(a_b0_r1, rdata);
    check_eq("hit RD", rdata, 32'hA5A5_5A5A);
    if (dram_bank_open[0] !== 1'b1) begin
      $error("[TB] bank0 should stay open after hit path");
      errs++;
    end

    // ------------------------------------------------------------------
    // 2) Page miss / same-bank row conflict: PRE→ACT→WR new row; old+new readable
    // ------------------------------------------------------------------
    $display("[TB] === SCENARIO 2: page miss (bank0 row 0x11 → 0x22) ===");
    host_write(a_b0_r2, 32'hBEEF_0002);
    // After miss, only new row should be open on bank0
    if (dram_bank_open[0] !== 1'b1) begin
      $error("[TB] bank0 should be open after miss WR");
      errs++;
    end
    host_read(a_b0_r2, rdata);
    check_eq("miss-new RD", rdata, 32'hBEEF_0002);
    // Re-open old row (another miss) and confirm data survived in array
    host_read(a_b0_r1, rdata);
    check_eq("miss-old RD", rdata, 32'hA5A5_5A5A);

    // ------------------------------------------------------------------
    // 3) Multi-bank: two banks open concurrently, then conflict on bank0 only
    // ------------------------------------------------------------------
    $display("[TB] === SCENARIO 3: multi-bank + bank0 row conflict ===");
    // a_b0_r1 left open from previous RD; open bank1
    host_write(a_b1_r3, 32'hC0DE_0001);
    if (dram_bank_open[0] !== 1'b1 || dram_bank_open[1] !== 1'b1) begin
      $error("[TB] expected bank0+bank1 open, got %b", dram_bank_open);
      errs++;
    end else begin
      $display("[TB] bank_open=%b (bank0+bank1) OK", dram_bank_open);
    end
    host_read(a_b1_r3, rdata);
    check_eq("bank1 hit RD", rdata, 32'hC0DE_0001);

    // Row conflict on bank0 while bank1 should remain open
    host_write(a_b0_r4, 32'hD00D_0004);
    if (dram_bank_open[1] !== 1'b1) begin
      $error("[TB] bank1 must stay open across bank0 conflict");
      errs++;
    end
    if (dram_bank_open[0] !== 1'b1) begin
      $error("[TB] bank0 should be open on new row after conflict");
      errs++;
    end
    host_read(a_b0_r4, rdata);
    check_eq("bank0 conflict RD", rdata, 32'hD00D_0004);
    host_read(a_b1_r3, rdata);
    check_eq("bank1 survived", rdata, 32'hC0DE_0001);

    // ------------------------------------------------------------------
    repeat (4) @(posedge clk);

    if (access_err_count != 0) begin
      $error("[TB] model access_err fired %0d time(s) — controller issued illegal RD/WR/ACT",
             access_err_count);
      errs++;
    end else begin
      $display("[TB] access_err count=0 OK");
    end

    if (errs == 0)
      $display("[TB] PASS — hit / page-miss / multi-bank conflict OK");
    else
      $error("[TB] FAIL — %0d error(s)", errs);

    $finish;
  end

  initial begin
    #500_000;
    $error("[TB] timeout");
    $finish;
  end

endmodule
