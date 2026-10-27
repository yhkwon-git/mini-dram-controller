// Simple synchronous DRAM model — latency / banks / page hit-miss stubs.
// Educational own-spec ONLY. Not JEDEC or HBM compliant.
`timescale 1ns/1ps

module dram_model
  import dram_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  input  dram_cmd_e               cmd,
  input  logic [$clog2(NUM_BANKS)-1:0] bank,
  input  logic [ROW_BITS-1:0]     row,
  input  logic [COL_BITS-1:0]     col,
  input  logic [DATA_BITS-1:0]    wdata,

  output logic                    busy,       // model still applying timing
  output logic                    data_valid,
  output logic [DATA_BITS-1:0]    rdata,
  output logic                    page_hit    // sticky hint for last ACT/RD/WR
);

  // Per-bank open-row tracking (stub)
  logic                  bank_open   [NUM_BANKS];
  logic [ROW_BITS-1:0]   bank_row    [NUM_BANKS];

  // Tiny storage: one word per (bank,row,col) — sparse stub via flat array
  // Size = NUM_BANKS * 2^ROW_BITS * 2^COL_BITS — kept small by params above.
  localparam int MEM_WORDS = NUM_BANKS * (1 << ROW_BITS) * (1 << COL_BITS);
  logic [DATA_BITS-1:0] mem [MEM_WORDS];

  logic [$clog2(tRFC+1)-1:0] timer;
  logic                      timer_active;

  function automatic int mem_index(
    input logic [$clog2(NUM_BANKS)-1:0] b,
    input logic [ROW_BITS-1:0] r,
    input logic [COL_BITS-1:0] c
  );
    return (b * (1 << (ROW_BITS + COL_BITS))) + (r * (1 << COL_BITS)) + c;
  endfunction

  // Skeleton: accept commands, track open rows; full timing later.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_BANKS; i++) begin
        bank_open[i] <= 1'b0;
        bank_row[i]  <= '0;
      end
      timer        <= '0;
      timer_active <= 1'b0;
      busy         <= 1'b0;
      data_valid   <= 1'b0;
      rdata        <= '0;
      page_hit     <= 1'b0;
    end else begin
      data_valid <= 1'b0;

      if (timer_active) begin
        if (timer == 0) begin
          timer_active <= 1'b0;
          busy         <= 1'b0;
        end else begin
          timer <= timer - 1'b1;
        end
      end else begin
        unique case (cmd)
          CMD_ACT: begin
            bank_open[bank] <= 1'b1;
            bank_row[bank]  <= row;
            page_hit        <= 1'b0;
            // TODO: enforce tRCD busy window
            busy            <= 1'b0;
          end
          CMD_PRE: begin
            bank_open[bank] <= 1'b0;
            page_hit        <= 1'b0;
            busy            <= 1'b0;
          end
          CMD_RD: begin
            page_hit   <= bank_open[bank] && (bank_row[bank] == row);
            rdata      <= mem[mem_index(bank, row, col)];
            data_valid <= 1'b1; // TODO: honor tCL
            busy       <= 1'b0;
          end
          CMD_WR: begin
            page_hit            <= bank_open[bank] && (bank_row[bank] == row);
            mem[mem_index(bank, row, col)] <= wdata;
            busy                <= 1'b0;
          end
          CMD_REF: begin
            // Close all banks; start placeholder RFC timer
            for (int i = 0; i < NUM_BANKS; i++)
              bank_open[i] <= 1'b0;
            timer        <= tRFC[$bits(timer)-1:0];
            timer_active <= 1'b1;
            busy         <= 1'b1;
            page_hit     <= 1'b0;
          end
          default: begin
            // NOP
          end
        endcase
      end
    end
  end

endmodule
