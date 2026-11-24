interface rp_apb_if (input logic clk, input logic rst_n);
  timeunit 1ns;
  timeprecision 1ps;

  logic        sel;
  logic        enable;
  logic        write;
  logic [11:0] addr;
  logic [31:0] wdata;
  logic [3:0]  strb;
  logic [31:0] rdata;
  logic        ready;
  logic        error;
  logic        irq;
endinterface
