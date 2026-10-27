// Minimal Verilator-friendly smoke TB — exercises reset + idle cycles.
// Functional RD/WR sequences are TODO (scheduler not finished).
`timescale 1ns/1ps

module tb_mem_ctrl
  import dram_pkg::*;
;

  logic clk;
  logic rst_n;

  logic              req_valid, req_ready, req_write;
  logic [ADDR_BITS-1:0] req_addr;
  logic [DATA_BITS-1:0] req_wdata;
  logic              rsp_valid, rsp_ready, rsp_err;
  logic [DATA_BITS-1:0] rsp_rdata;

  int unsigned cycle;

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

  // 100 MHz-ish
  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rst_n     = 1'b0;
    req_valid = 1'b0;
    req_write = 1'b0;
    req_addr  = '0;
    req_wdata = '0;
    rsp_ready = 1'b1;
    cycle     = 0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // Smoke: hold idle; later inject host transactions when scheduler lands
    repeat (20) @(posedge clk);

    $display("[TB] smoke OK — idle cycles complete (functional tests TODO)");
    $finish;
  end

  always_ff @(posedge clk) begin
    if (rst_n)
      cycle <= cycle + 1;
  end

  // Timeout watchdog
  initial begin
    #10_000;
    $error("[TB] timeout");
    $finish;
  end

endmodule
