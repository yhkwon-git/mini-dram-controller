// Classes for the random testbench (tb/tb_mem_ctrl_rand.sv). The roles follow
// UVM without the library:
//
//   mc_sequence -> mc_driver -> host port -> mc_monitor
//                      |                         |
//                      +--- accepted requests --> mc_scoreboard <-- responses
//
// mc_responder drives rsp_ready with random back-pressure, mc_coverage counts
// functional bins, and mc_env builds, runs and reports the whole thing.
`timescale 1ns/1ps

// The lint pass does not follow reads and writes through class handles, so it
// reports class members as unused or undriven.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off DECLFILENAME */
package mc_tb_pkg;
  import dram_pkg::*;

  localparam int BANK_BITS   = $clog2(NUM_BANKS);
  localparam int HANG_CYCLES = 4000;  // no response for this long = the controller is stuck
  localparam int MAX_REPORTS = 20;

  typedef enum int { P_SEQ, P_RAND, P_STRIDE, P_HOTBANK, P_ROWHIT, P_MIXED } pattern_e;
  typedef enum int { COL_HIT, COL_MISS, COL_CONFLICT } col_kind_e;

  typedef enum int {
    CV_RD_HIT, CV_RD_MISS, CV_RD_CONFLICT,
    CV_WR_HIT, CV_WR_MISS, CV_WR_CONFLICT,
    CV_INFLIGHT_4,      // 4+ requests accepted and not yet answered
    CV_INFLIGHT_8,
    CV_INFLIGHT_15,     // the response-tag limit
    CV_BANKS_4,         // requests to all four banks in flight at once
    CV_RAW,             // read accepted while a write to the same address is in flight
    CV_WAW,             // write accepted while a write to the same address is in flight
    CV_REQ_STALL_TAGS,  // request held back because 15 are in flight
    CV_RSP_STALL_16,    // a response waited 16+ cycles on rsp_ready
    CV_REF_OWED,        // REF while responses are still owed to the host
    CV_REF_STALLED,     // REF while a finished response waits on rsp_ready
    CV_REORDER,         // a column command serves a request ahead of an older one
    CV_N
  } cov_bin_e;

  function automatic string pad(string s, int w);
    string r;
    r = s;
    while (r.len() < w) r = {r, " "};
    return r;
  endfunction

  // xorshift64*: the same seed gives the same run on any simulator.
  class mc_rng;
    local bit [63:0] s;

    function new(longint unsigned seed);
      s = 64'h9E37_79B9_7F4A_7C15 ^ 64'(seed);
      if (s == 64'd0) s = 64'd1;
    endfunction

    function bit [31:0] next();
      bit [63:0] m;
      s = s ^ (s >> 12);
      s = s ^ (s << 25);
      s = s ^ (s >> 27);
      m = s * 64'h2545_F491_4F6C_DD1D;
      return m[63:32];
    endfunction

    function int unsigned below(int unsigned n);  // 0 .. n-1
      return (n == 0) ? 0 : next() % n;
    endfunction

    function bit chance(int unsigned pct);  // true pct% of the time
      return below(100) < pct;
    endfunction
  endclass

  class mc_cfg;
    string           pattern_name = "mixed";
    pattern_e        pattern      = P_MIXED;
    longint unsigned seed         = 1;
    int unsigned     n_txn        = 2000;
    int unsigned     rd_pct       = 50;  // share of reads
    int unsigned     gap_max      = 2;   // idle cycles between requests: 0 .. gap_max
    int unsigned     bp_pct       = 10;  // chance per cycle that a response stall starts
    int unsigned     bp_max       = 24;  // longest stall in cycles
    int unsigned     stride       = 16;  // P_STRIDE step in words (16 = next row, same bank)
    int unsigned     hot_pct      = 80;  // P_HOTBANK share of requests to bank 0
    int unsigned     reuse_pct    = 20;  // chance to reuse a recently written address
    string           csv          = "";  // append one result line to this file

    function bit from_plusargs();
      void'($value$plusargs("PATTERN=%s", pattern_name));
      void'($value$plusargs("SEED=%d", seed));
      void'($value$plusargs("N=%d", n_txn));
      void'($value$plusargs("RD_PCT=%d", rd_pct));
      void'($value$plusargs("GAP_MAX=%d", gap_max));
      void'($value$plusargs("BP_PCT=%d", bp_pct));
      void'($value$plusargs("BP_MAX=%d", bp_max));
      void'($value$plusargs("STRIDE=%d", stride));
      void'($value$plusargs("HOT_PCT=%d", hot_pct));
      void'($value$plusargs("REUSE_PCT=%d", reuse_pct));
      void'($value$plusargs("CSV=%s", csv));
      if      (pattern_name == "seq")     pattern = P_SEQ;
      else if (pattern_name == "rand")    pattern = P_RAND;
      else if (pattern_name == "stride")  pattern = P_STRIDE;
      else if (pattern_name == "hotbank") pattern = P_HOTBANK;
      else if (pattern_name == "rowhit")  pattern = P_ROWHIT;
      else if (pattern_name == "mixed")   pattern = P_MIXED;
      else return 1'b0;
      return 1'b1;
    endfunction

    function string show();
      return $sformatf("pattern=%s seed=%0d n=%0d rd=%0d%% gap<=%0d bp=%0d%%/%0d stride=%0d hot=%0d%% reuse=%0d%%",
                       pattern_name, seed, n_txn, rd_pct, gap_max, bp_pct, bp_max, stride,
                       hot_pct, reuse_pct);
    endfunction
  endclass

  class mc_txn;
    int unsigned          id;
    bit                   write;
    logic [ADDR_BITS-1:0] addr;
    logic [DATA_BITS-1:0] wdata;
    logic [DATA_BITS-1:0] exp_rdata;  // set by the scoreboard when the request is accepted
    longint               t_accept;
    bit                   col_issued; // its RD/WR has appeared on the DRAM pins

    function string show();
      return $sformatf("#%0d %s bank %0d row %02h col %0h", id, write ? "WR" : "RD",
                       addr_bank(addr), addr_row(addr), addr_col(addr));
    endfunction
  endclass

  class mc_rsp;
    logic [DATA_BITS-1:0] rdata;
    bit                   err;
    longint               t;
  endclass

  // Address streams. P_MIXED picks one of the other five per request.
  class mc_sequence;
    mc_cfg            cfg;
    mc_rng            rng;
    mailbox #(mc_txn) out;
    local logic [ADDR_BITS-1:0] cursor;
    local logic [ROW_BITS-1:0]  hot_row [NUM_BANKS];
    local logic [ADDR_BITS-1:0] recent [$];

    function new(mc_cfg c, mc_rng r, mailbox #(mc_txn) m);
      cfg    = c;
      rng    = r;
      out    = m;
      cursor = ADDR_BITS'(rng.next());
      for (int b = 0; b < NUM_BANKS; b++) hot_row[b] = ROW_BITS'(rng.next());
    endfunction

    function logic [ADDR_BITS-1:0] addr_for(pattern_e p);
      logic [ADDR_BITS-1:0] a;
      logic [BANK_BITS-1:0] b;
      case (p)
        P_SEQ: begin
          a      = cursor;
          cursor = cursor + 1'b1;
        end
        P_STRIDE: begin
          a      = cursor;
          cursor = cursor + ADDR_BITS'(cfg.stride);
        end
        P_HOTBANK: begin
          b = rng.chance(cfg.hot_pct) ? '0 : BANK_BITS'(rng.next());
          a = {b, ROW_BITS'(rng.next()), COL_BITS'(rng.next())};
        end
        P_ROWHIT: begin  // one fixed row per bank: hits once the rows are open
          b = BANK_BITS'(rng.next());
          a = {b, hot_row[b], COL_BITS'(rng.next())};
        end
        default: a = ADDR_BITS'(rng.next());  // P_RAND
      endcase
      return a;
    endfunction

    function mc_txn next(int unsigned id);
      mc_txn    t;
      pattern_e p;
      t       = new();
      t.id    = id;
      t.write = !rng.chance(cfg.rd_pct);
      p       = cfg.pattern;
      if (p == P_MIXED) p = pattern_e'(rng.below(5));
      if (recent.size() != 0 && rng.chance(cfg.reuse_pct))
        t.addr = recent[rng.below(recent.size())];
      else
        t.addr = addr_for(p);
      t.wdata = rng.next();
      if (t.write) begin
        recent.push_back(t.addr);
        if (recent.size() > 16) void'(recent.pop_front());
      end
      return t;
    endfunction

    task run();
      for (int unsigned i = 0; i < cfg.n_txn; i++) out.put(next(i));
    endtask
  endclass

  // Drives the request side. Changes inputs on the falling edge; a request is
  // accepted on the rising edge that sees req_valid && req_ready.
  class mc_driver;
    virtual mc_host_if vif;
    mc_cfg             cfg;
    mc_rng             rng;
    mailbox #(mc_txn)  in;
    mailbox #(mc_txn)  accepted;
    int unsigned       n_sent;

    function new(virtual mc_host_if v, mc_cfg c, mc_rng r, mailbox #(mc_txn) i,
                 mailbox #(mc_txn) a);
      vif      = v;
      cfg      = c;
      rng      = r;
      in       = i;
      accepted = a;
      n_sent   = 0;
    endfunction

    task idle();
      vif.req_valid = 1'b0;
      vif.req_write = 1'b0;
      vif.req_addr  = '0;
      vif.req_wdata = '0;
    endtask

    task run();
      mc_txn       t;
      int unsigned gap;
      @(negedge vif.clk);
      idle();
      forever begin
        // At a falling edge. Drop req_valid while there is nothing to send.
        if (in.try_get(t) == 0) begin
          idle();
          in.get(t);
          @(negedge vif.clk);
        end
        gap = rng.below(cfg.gap_max + 1);
        if (gap != 0) begin
          idle();
          repeat (gap) @(negedge vif.clk);
        end
        vif.req_valid = 1'b1;
        vif.req_write = t.write;
        vif.req_addr  = t.addr;
        vif.req_wdata = t.wdata;
        @(posedge vif.clk);
        while (vif.req_ready !== 1'b1) @(posedge vif.clk);
        t.t_accept = vif.cyc;
        accepted.put(t);
        n_sent++;
        @(negedge vif.clk);
      end
    endtask
  endclass

  // Drives rsp_ready: random stalls of 1 .. bp_max cycles.
  class mc_responder;
    virtual mc_host_if vif;
    mc_cfg             cfg;
    mc_rng             rng;

    function new(virtual mc_host_if v, mc_cfg c, mc_rng r);
      vif = v;
      cfg = c;
      rng = r;
    endfunction

    task init();
      vif.rsp_ready = 1'b1;
    endtask

    task run();
      int unsigned left;
      left = 0;
      init();
      forever begin
        @(negedge vif.clk);
        if (left == 0 && cfg.bp_pct != 0 && rng.chance(cfg.bp_pct))
          left = 1 + rng.below(cfg.bp_max);
        if (left != 0) begin
          vif.rsp_ready = 1'b0;
          left--;
        end else begin
          vif.rsp_ready = 1'b1;
        end
      end
    endtask
  endclass

  // Collects every response the host takes.
  class mc_monitor;
    virtual mc_host_if vif;
    mailbox #(mc_rsp)  out;

    function new(virtual mc_host_if v, mailbox #(mc_rsp) o);
      vif = v;
      out = o;
    endfunction

    task run();
      mc_rsp r;
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n === 1'b1 && vif.rsp_valid === 1'b1 && vif.rsp_ready === 1'b1) begin
          r       = new();
          r.rdata = vif.rsp_rdata;
          r.err   = vif.rsp_err;
          r.t     = vif.cyc;
          out.put(r);
        end
      end
    endtask
  endclass

  class mc_coverage;
    longint hits       [CV_N];
    string  label      [CV_N];
    string  short_name [CV_N];

    function new();
      label[CV_RD_HIT]         = "read, row hit";
      label[CV_RD_MISS]        = "read, bank closed (ACT)";
      label[CV_RD_CONFLICT]    = "read, row conflict (PRE + ACT)";
      label[CV_WR_HIT]         = "write, row hit";
      label[CV_WR_MISS]        = "write, bank closed (ACT)";
      label[CV_WR_CONFLICT]    = "write, row conflict (PRE + ACT)";
      label[CV_INFLIGHT_4]     = "4+ requests in flight";
      label[CV_INFLIGHT_8]     = "8+ requests in flight";
      label[CV_INFLIGHT_15]    = "15 in flight (tag limit)";
      label[CV_BANKS_4]        = "all four banks in flight";
      label[CV_RAW]            = "read after write, same address";
      label[CV_WAW]            = "write after write, same address";
      label[CV_REQ_STALL_TAGS] = "request held at the tag limit";
      label[CV_RSP_STALL_16]   = "response waits 16+ cycles";
      label[CV_REF_OWED]       = "REF with responses still owed";
      label[CV_REF_STALLED]    = "REF while rsp_ready is low";
      label[CV_REORDER]        = "column command passes an older request";
      short_name[CV_RD_HIT]         = "rd_hit";
      short_name[CV_RD_MISS]        = "rd_miss";
      short_name[CV_RD_CONFLICT]    = "rd_conflict";
      short_name[CV_WR_HIT]         = "wr_hit";
      short_name[CV_WR_MISS]        = "wr_miss";
      short_name[CV_WR_CONFLICT]    = "wr_conflict";
      short_name[CV_INFLIGHT_4]     = "inflight_4";
      short_name[CV_INFLIGHT_8]     = "inflight_8";
      short_name[CV_INFLIGHT_15]    = "inflight_15";
      short_name[CV_BANKS_4]        = "banks_4";
      short_name[CV_RAW]            = "raw";
      short_name[CV_WAW]            = "waw";
      short_name[CV_REQ_STALL_TAGS] = "req_stall_tags";
      short_name[CV_RSP_STALL_16]   = "rsp_stall_16";
      short_name[CV_REF_OWED]       = "ref_owed";
      short_name[CV_REF_STALLED]    = "ref_stalled";
      short_name[CV_REORDER]        = "reorder";
      foreach (hits[i]) hits[i] = 0;
    endfunction

    function void hit(cov_bin_e b);
      hits[b]++;
    endfunction

    function int unsigned holes();
      int unsigned n;
      n = 0;
      foreach (hits[i]) if (hits[i] == 0) n++;
      return n;
    endfunction

    function void report();
      $display("[COV] functional bins hit: %0d / %0d", int'(CV_N) - int'(holes()), int'(CV_N));
      foreach (hits[i])
        $display("[COV]   %s %0d", pad(label[i], 34), hits[i]);
    endfunction
  endclass

  // Predicts each response when its request is accepted. Same-address order
  // holds because one bank engine serves one request at a time, oldest first,
  // so a read accepted after a write to its address must see that write.
  class mc_scoreboard;
    mailbox #(mc_txn)     accepted;
    mailbox #(mc_rsp)     responses;
    mc_coverage           cov;
    logic [DATA_BITS-1:0] mem [logic [ADDR_BITS-1:0]];  // reference memory
    mc_txn                pending [$];                  // accepted, not yet answered
    longint               lat [$];                      // accept -> response, cycles
    int unsigned          n_acc, n_rsp, n_bad, n_report;
    longint               t_first, t_last;

    function new(mailbox #(mc_txn) a, mailbox #(mc_rsp) r, mc_coverage c);
      accepted  = a;
      responses = r;
      cov       = c;
      n_acc     = 0;
      n_rsp     = 0;
      n_bad     = 0;
      n_report  = 0;
      t_first   = -1;
      t_last    = 0;
    endfunction

    function void fail(string msg);
      n_bad++;
      if (n_report < MAX_REPORTS) begin
        n_report++;
        $display("[SB] MISMATCH %s", msg);
      end
    endfunction

    function void predict(mc_txn t);
      bit                 raw, waw;
      bit [NUM_BANKS-1:0] banks;
      raw   = 1'b0;
      waw   = 1'b0;
      banks = '0;
      foreach (pending[i]) begin
        banks[addr_bank(pending[i].addr)] = 1'b1;
        if (pending[i].write && pending[i].addr == t.addr) begin
          if (t.write) waw = 1'b1;
          else         raw = 1'b1;
        end
      end
      if (t.write) begin
        mem[t.addr] = t.wdata;
        t.exp_rdata = '0;  // a write answers with rsp_rdata = 0 (docs/spec.md, section 4)
      end else begin
        t.exp_rdata = mem.exists(t.addr) ? mem[t.addr] : '0;  // the model resets to 0
      end
      pending.push_back(t);
      banks[addr_bank(t.addr)] = 1'b1;
      n_acc++;
      if (t_first < 0) t_first = t.t_accept;
      if (raw)                  cov.hit(CV_RAW);
      if (waw)                  cov.hit(CV_WAW);
      if (&banks)               cov.hit(CV_BANKS_4);
      if (pending.size() >= 4)  cov.hit(CV_INFLIGHT_4);
      if (pending.size() >= 8)  cov.hit(CV_INFLIGHT_8);
      if (pending.size() >= 15) cov.hit(CV_INFLIGHT_15);
    endfunction

    function void compare(mc_rsp r);
      mc_txn t;
      n_rsp++;
      t_last = r.t;
      if (pending.size() == 0) begin
        fail($sformatf("response at cycle %0d with nothing outstanding", r.t));
        return;
      end
      t = pending.pop_front();
      lat.push_back(r.t - t.t_accept);
      if (!t.col_issued)
        fail($sformatf("%s: answered before its RD/WR reached the DRAM", t.show()));
      if (r.err)
        fail($sformatf("%s: rsp_err set", t.show()));
      if (r.rdata !== t.exp_rdata)
        fail($sformatf("%s: data %08h, expected %08h", t.show(), r.rdata, t.exp_rdata));
    endfunction

    task run();
      mc_txn t;
      mc_rsp r;
      fork
        forever begin
          accepted.get(t);
          predict(t);
        end
        forever begin
          responses.get(r);
          compare(r);
        end
      join
    endtask
  endclass

  class mc_env;
    mc_cfg             cfg;
    virtual mc_host_if vif;
    mc_coverage        cov;
    mc_sequence        seq;
    mc_driver          drv;
    mc_responder       rsp;
    mc_monitor         mon;
    mc_scoreboard      sb;
    mailbox #(mc_txn)  seq2drv;
    mailbox #(mc_txn)  drv2sb;
    mailbox #(mc_rsp)  mon2sb;

    // DRAM-side activity, fed by the testbench top from the command pins
    longint      col_kind [2][3];  // [write][col_kind_e]
    longint      data_beats;
    bit          hung;
    int unsigned stall_run;

    // Results of report(), also written to the CSV line
    longint span, lat_p50, lat_p99, lat_max;
    real    lat_avg, util_pct, hit_pct;

    function new(virtual mc_host_if v);
      vif        = v;
      cfg        = new();
      cov        = new();
      data_beats = 0;
      hung       = 1'b0;
      stall_run  = 0;
      for (int w = 0; w < 2; w++)
        for (int k = 0; k < 3; k++) col_kind[w][k] = 0;
    endfunction

    function void build();
      mc_rng r_seq, r_drv, r_rsp;
      r_seq   = new(cfg.seed * 3 + 1);
      r_drv   = new(cfg.seed * 3 + 2);
      r_rsp   = new(cfg.seed * 3 + 3);
      seq2drv = new();
      drv2sb  = new();
      mon2sb  = new();
      seq     = new(cfg, r_seq, seq2drv);
      drv     = new(vif, cfg, r_drv, seq2drv, drv2sb);
      rsp     = new(vif, cfg, r_rsp);
      mon     = new(vif, mon2sb);
      sb      = new(drv2sb, mon2sb, cov);
    endfunction

    // Cycle-level coverage on the host port.
    task sample();
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n === 1'b1) begin
          if (vif.req_valid === 1'b1 && vif.req_ready !== 1'b1 && sb.pending.size() >= 15)
            cov.hit(CV_REQ_STALL_TAGS);
          if (vif.rsp_valid === 1'b1 && vif.rsp_ready !== 1'b1) begin
            stall_run++;
            if (stall_run == 16) cov.hit(CV_RSP_STALL_16);
          end else begin
            stall_run = 0;
          end
        end
      end
    endtask

    // Returns once every request has a checked response, or when nothing has
    // been answered for HANG_CYCLES.
    task run();
      int unsigned last_n;
      longint      last_t;
      fork
        seq.run();
        drv.run();
        rsp.run();
        mon.run();
        sb.run();
        sample();
      join_none
      last_n = 0;
      last_t = vif.cyc;
      while (sb.n_rsp < cfg.n_txn && !hung) begin
        @(posedge vif.clk);
        if (sb.n_rsp != last_n) begin
          last_n = sb.n_rsp;
          last_t = vif.cyc;
        end else if (vif.cyc - last_t > longint'(HANG_CYCLES)) begin
          hung = 1'b1;
        end
      end
      repeat (40) @(posedge vif.clk);  // an extra response would arrive here
    endtask

    function void note_col(bit write, col_kind_e k);
      col_kind[write][k]++;
      cov.hit(cov_bin_e'(int'(write) * 3 + int'(k)));
    endfunction

    // Match a RD/WR on the DRAM pins to the oldest pending request with the same
    // address and direction. Serving it while an older request still waits for its
    // own RD/WR is a reorder (legal across banks); no match at all is an error.
    function void note_col_cmd(bit write, logic [ADDR_BITS-1:0] a);
      bit older_waiting;
      older_waiting = 1'b0;
      foreach (sb.pending[i]) begin
        if (!sb.pending[i].col_issued) begin
          if (sb.pending[i].addr == a && sb.pending[i].write == write) begin
            sb.pending[i].col_issued = 1'b1;
            if (older_waiting) cov.hit(CV_REORDER);
            return;
          end
          older_waiting = 1'b1;
        end
      end
      sb.fail($sformatf("%s to bank %0d row %02h col %0h matches no pending request",
                        write ? "WR" : "RD", addr_bank(a), addr_row(a), addr_col(a)));
    endfunction

    function void note_beat();
      data_beats++;
    endfunction

    function void note_ref();
      if (sb.pending.size() != 0) cov.hit(CV_REF_OWED);
      if (vif.rsp_valid === 1'b1 && vif.rsp_ready !== 1'b1) cov.hit(CV_REF_STALLED);
    endfunction

    function int unsigned report();
      longint      s [$];
      longint      sum, hits, total;
      int unsigned problems;
      s = sb.lat;
      s.sort();
      sum = 0;
      foreach (s[i]) sum += s[i];
      lat_avg = (s.size() != 0) ? real'(sum) / real'(s.size()) : 0.0;
      lat_p50 = (s.size() != 0) ? s[(s.size() - 1) / 2] : 0;
      lat_p99 = (s.size() != 0) ? s[(s.size() * 99 + 99) / 100 - 1] : 0;
      lat_max = (s.size() != 0) ? s[s.size() - 1] : 0;
      span     = (sb.t_first >= 0) ? sb.t_last - sb.t_first + 1 : 0;
      util_pct = (span > 0) ? 100.0 * real'(data_beats) / real'(span) : 0.0;
      hits  = col_kind[0][COL_HIT] + col_kind[1][COL_HIT];
      total = 0;
      for (int w = 0; w < 2; w++)
        for (int k = 0; k < 3; k++) total += col_kind[w][k];
      hit_pct = (total != 0) ? 100.0 * real'(hits) / real'(total) : 0.0;

      problems = sb.n_bad;
      if (hung) begin
        $display("[RAND] ERROR no response for %0d cycles: %0d of %0d answered, %0d pending",
                 HANG_CYCLES, sb.n_rsp, cfg.n_txn, sb.pending.size());
        problems++;
      end
      if (sb.n_rsp != cfg.n_txn) begin
        $display("[RAND] ERROR %0d responses for %0d requests", sb.n_rsp, cfg.n_txn);
        problems++;
      end

      $display("[RAND] responses %0d/%0d, data mismatches %0d", sb.n_rsp, cfg.n_txn, sb.n_bad);
      $display("[RAND] span %0d cycles, data bus busy %0.1f%%", span, util_pct);
      $display("[RAND] latency (accept -> response) avg %0.1f, p50 %0d, p99 %0d, max %0d cycles",
               lat_avg, lat_p50, lat_p99, lat_max);
      $display("[RAND] read hit/miss/conflict %0d/%0d/%0d, write %0d/%0d/%0d, row hit rate %0.1f%%",
               col_kind[0][COL_HIT], col_kind[0][COL_MISS], col_kind[0][COL_CONFLICT],
               col_kind[1][COL_HIT], col_kind[1][COL_MISS], col_kind[1][COL_CONFLICT], hit_pct);
      cov.report();
      return problems;
    endfunction

    function void write_csv(int unsigned problems, int unsigned violations, int unsigned waived,
                            longint n_ref, real ref_avg, longint ref_max, longint debt_max);
      int    fd;
      bit    need_header;
      string line;
      string result;
      if (cfg.csv == "") return;
      fd          = $fopen(cfg.csv, "r");
      need_header = (fd == 0);
      if (fd != 0) $fclose(fd);
      fd = $fopen(cfg.csv, "a");
      if (fd == 0) begin
        $display("[RAND] WARNING cannot open %s", cfg.csv);
        return;
      end
      if (need_header) begin
        line = {"pattern,seed,n,result,problems,span,util_pct,lat_avg,lat_p50,lat_p99,lat_max,",
                "rd_hit,rd_miss,rd_conflict,wr_hit,wr_miss,wr_conflict,hit_pct,",
                "refs,ref_int_avg,ref_int_max,ref_debt_max,violations,waived,mismatches"};
        foreach (cov.short_name[i]) line = {line, ",cv_", cov.short_name[i]};
        $fdisplay(fd, "%s", line);
      end
      result = (problems == 0) ? "PASS" : "FAIL";
      line = $sformatf("%s,%0d,%0d,%s,%0d,%0d,%0.2f,%0.2f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.2f,%0d,%0.2f,%0d,%0d,%0d,%0d,%0d",
                       cfg.pattern_name, cfg.seed, cfg.n_txn, result, problems, span, util_pct,
                       lat_avg, lat_p50, lat_p99, lat_max,
                       col_kind[0][COL_HIT], col_kind[0][COL_MISS], col_kind[0][COL_CONFLICT],
                       col_kind[1][COL_HIT], col_kind[1][COL_MISS], col_kind[1][COL_CONFLICT],
                       hit_pct, n_ref, ref_avg, ref_max, debt_max, violations, waived, sb.n_bad);
      foreach (cov.hits[i]) line = {line, $sformatf(",%0d", cov.hits[i])};
      $fdisplay(fd, "%s", line);
      $fclose(fd);
    endfunction
  endclass

endpackage
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
