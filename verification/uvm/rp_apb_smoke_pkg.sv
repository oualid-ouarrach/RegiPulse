`include "uvm_macros.svh"

package rp_apb_smoke_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import rp_apb_pkg::*;

  class rp_apb_smoke_sequence extends uvm_sequence #(rp_apb_item);
    `uvm_object_utils(rp_apb_smoke_sequence)

    bit after_transfer;

    function new(string name = "rp_apb_smoke_sequence");
      super.new(name);
    endfunction

    task access(bit write, logic [11:0] addr, logic [31:0] data = '0);
      rp_apb_item item = rp_apb_item::type_id::create("request");
      start_item(item);
      item.write = write;
      item.addr = addr;
      item.data = data;
      item.strb = write ? 4'hf : 4'h0;
      finish_item(item);
    endtask

    task body();
      if (!after_transfer) begin
        access(0, 12'h024);       // ID
        access(0, 12'h00c);       // Reset status
        access(1, 12'h020, 1);    // Enable DONE IRQ
        access(1, 12'h010, 'ha6); // Queue one byte
        access(1, 12'h008, 1);    // Start mode-0 frame with reset configuration
        access(0, 12'h00c);       // Busy status
      end else begin
        access(0, 12'h01c);       // DONE event
        access(0, 12'h00c);       // Idle with a queued RX byte
        access(0, 12'h014);       // Read MISO byte
        access(0, 12'h018);       // Both FIFOs empty
        access(1, 12'h01c, 1);    // Clear DONE
        access(0, 12'h040);       // Unmapped address
        access(0, 12'h01c);       // Masked ACCESS event remains sticky
      end
    endtask
  endclass

  class rp_apb_smoke_scoreboard extends uvm_subscriber #(rp_apb_item);
    `uvm_component_utils(rp_apb_smoke_scoreboard)

    typedef struct packed {
      logic        write;
      logic [11:0] addr;
      logic [31:0] data;
      logic [3:0]  strb;
      logic        error;
    } expectation_t;

    expectation_t expected[$];
    int observed_count;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void expect_access(logic write, logic [11:0] addr, logic [31:0] data,
                                logic error = 1'b0);
      expectation_t entry;
      entry = '{write, addr, data, write ? 4'hf : 4'h0, error};
      expected.push_back(entry);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      expect_access(0, 12'h024, $test$plusargs("RP_FORCE_MISMATCH") ? 32'h0 : 32'h5250_4701);
      expect_access(0, 12'h00c, 32'h0a);
      expect_access(1, 12'h020, 32'h01);
      expect_access(1, 12'h010, 32'ha6);
      expect_access(1, 12'h008, 32'h01);
      expect_access(0, 12'h00c, 32'h0b);
      expect_access(0, 12'h01c, 32'h01);
      expect_access(0, 12'h00c, 32'h02);
      expect_access(0, 12'h014, 32'h3d);
      expect_access(0, 12'h018, 32'h00);
      expect_access(1, 12'h01c, 32'h01);
      expect_access(0, 12'h040, 32'h00, 1'b1);
      expect_access(0, 12'h01c, 32'h20);
    endfunction

    function void write(rp_apb_item item);
      expectation_t entry;
      observed_count++;
      if (expected.size() == 0) begin
        `uvm_error("APB_CHECK", $sformatf("Unexpected transfer at 0x%03h", item.addr))
        return;
      end
      entry = expected.pop_front();
      if ({item.write, item.addr, item.data, item.strb, item.error} !== entry)
        `uvm_error("APB_CHECK", $sformatf(
          "Transfer %0d expected wr=%b addr=%03h data=%08h strb=%h err=%b, got wr=%b addr=%03h data=%08h strb=%h err=%b",
          observed_count, entry.write, entry.addr, entry.data, entry.strb, entry.error,
          item.write, item.addr, item.data, item.strb, item.error))
    endfunction

    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (expected.size() != 0)
        `uvm_error("APB_CHECK", $sformatf("Missing %0d APB transfers", expected.size()))
      `uvm_info("APB_CHECK", $sformatf("Observed %0d APB transfers", observed_count), UVM_LOW)
    endfunction
  endclass

  class rp_apb_smoke_test extends uvm_test;
    `uvm_component_utils(rp_apb_smoke_test)

    virtual rp_apb_if vif;
    rp_apb_agent agent;
    rp_apb_smoke_scoreboard scoreboard;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual rp_apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("APB_CFG", "APB test requires a virtual interface")
      agent = rp_apb_agent::type_id::create("agent", this);
      scoreboard = rp_apb_smoke_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.observed.connect(scoreboard.analysis_export);
    endfunction

    task run_phase(uvm_phase phase);
      rp_apb_smoke_sequence start_frame, check_frame;
      phase.raise_objection(this);
      start_frame = rp_apb_smoke_sequence::type_id::create("start_frame");
      check_frame = rp_apb_smoke_sequence::type_id::create("check_frame");
      check_frame.after_transfer = 1'b1;
      start_frame.start(agent.sequencer);
      wait (vif.irq === 1'b1);
      check_frame.start(agent.sequencer);
      if (vif.irq !== 1'b0)
        `uvm_error("IRQ_CHECK", "IRQ is high after clearing DONE with ACCESS masked")
      phase.drop_objection(this);
    endtask
  endclass
endpackage
