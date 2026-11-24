`include "uvm_macros.svh"

package rp_apb_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;

  class rp_apb_item extends uvm_sequence_item;
    `uvm_object_utils(rp_apb_item)

    logic        write;
    logic [11:0] addr;
    logic [31:0] data;
    logic [3:0]  strb;
    logic        error;

    function new(string name = "rp_apb_item");
      super.new(name);
    endfunction
  endclass

  class rp_apb_sequencer extends uvm_sequencer #(rp_apb_item);
    `uvm_component_utils(rp_apb_sequencer)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class rp_apb_driver extends uvm_driver #(rp_apb_item);
    `uvm_component_utils(rp_apb_driver)

    virtual rp_apb_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual rp_apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("APB_CFG", "APB driver requires a virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
      rp_apb_item item;

      vif.sel = 1'b0;
      vif.enable = 1'b0;
      vif.write = 1'b0;
      vif.addr = '0;
      vif.wdata = '0;
      vif.strb = '0;
      wait (vif.rst_n);
      forever begin
        seq_item_port.get_next_item(item);
        @(negedge vif.clk);
        vif.sel = 1'b1;
        vif.enable = 1'b0;
        vif.write = item.write;
        vif.addr = item.addr;
        vif.wdata = item.data;
        vif.strb = item.strb;
        @(negedge vif.clk);
        vif.enable = 1'b1;
        do @(posedge vif.clk); while (!vif.ready);
        @(negedge vif.clk);
        vif.sel = 1'b0;
        vif.enable = 1'b0;
        vif.strb = '0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class rp_apb_monitor extends uvm_monitor;
    `uvm_component_utils(rp_apb_monitor)

    virtual rp_apb_if vif;
    uvm_analysis_port #(rp_apb_item) observed;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      observed = new("observed", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual rp_apb_if)::get(this, "", "vif", vif))
        `uvm_fatal("APB_CFG", "APB monitor requires a virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
      rp_apb_item item;
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n && vif.sel && vif.enable && vif.ready) begin
          item = rp_apb_item::type_id::create("observed_item");
          item.write = vif.write;
          item.addr = vif.addr;
          item.data = vif.write ? vif.wdata : vif.rdata;
          item.strb = vif.strb;
          item.error = vif.error;
          observed.write(item);
        end
      end
    endtask
  endclass

  class rp_apb_agent extends uvm_agent;
    `uvm_component_utils(rp_apb_agent)

    rp_apb_sequencer sequencer;
    rp_apb_driver driver;
    rp_apb_monitor monitor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      monitor = rp_apb_monitor::type_id::create("monitor", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sequencer = rp_apb_sequencer::type_id::create("sequencer", this);
        driver = rp_apb_driver::type_id::create("driver", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (get_is_active() == UVM_ACTIVE)
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass
endpackage
