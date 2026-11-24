module rp_core_properties #(
  parameter integer NUM_CS = 4
) (
  input logic              clk_i,
  input logic              rst_ni,
  input logic [NUM_CS-1:0] cs_no,
  input logic              busy,
  input logic              spi_done,
  input logic              spi_busy,
  input logic              start,
  input logic              abort_frame,
  input logic              tx_empty,
  input logic              rx_empty,
  input logic              rx_full,
  input logic              rx_pop,
  input logic              rx_push,
  input logic [7:0]        events,
  input logic [7:0]        irq_status,
  input logic [7:0]        irq_enable,
  input logic              irq_o
);
  default clocking cb @(posedge clk_i); endclocking

  reset_state: assert property (!rst_ni |=> !busy && (&cs_no) &&
                               tx_empty && rx_empty && irq_status == 0 &&
                               irq_enable == 0 && !irq_o);
  chip_select: assert property (disable iff (!rst_ni)
    $onehot0(~cs_no) && (spi_busy == (cs_no != '1)));
  start_requires_data: assert property (disable iff (!rst_ni)
    start |-> !busy && !tx_empty);
  abort_stops_frame: assert property (disable iff (!rst_ni)
    abort_frame |=> !spi_busy && !spi_done && (&cs_no) && irq_status[7]);
  completion_is_atomic: assert property (disable iff (!rst_ni)
    spi_done |-> busy && !spi_busy && events[0]);
  receive_overflow: assert property (disable iff (!rst_ni)
    spi_done && rx_full && !rx_pop |-> !rx_push && events[3]);
  receive_accept: assert property (disable iff (!rst_ni)
    spi_done && (!rx_full || rx_pop) |-> rx_push && !events[3]);
  event_priority: assert property (disable iff (!rst_ni)
    (|events) |=> (irq_status & $past(events)) == $past(events));
  irq_mask: assert property (disable iff (!rst_ni)
    irq_o == (|(irq_status & irq_enable)));
endmodule

module rp_axil_properties (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        bvalid_o,
  input logic        bready_i,
  input logic [1:0]  bresp_o,
  input logic        rvalid_o,
  input logic        rready_i,
  input logic [1:0]  rresp_o,
  input logic [31:0] rdata_o
);
  default clocking cb @(posedge clk_i); endclocking

  reset_channels: assert property (!rst_ni |=> !bvalid_o && !rvalid_o);
  hold_write_response: assert property (disable iff (!rst_ni)
    bvalid_o && !bready_i |=> bvalid_o && $stable(bresp_o));
  hold_read_response: assert property (disable iff (!rst_ni)
    rvalid_o && !rready_i |=> rvalid_o && $stable({rresp_o, rdata_o}));
endmodule

bind regipulse_core rp_core_properties #(.NUM_CS(NUM_CS)) core_properties (
  .clk_i, .rst_ni, .cs_no, .busy, .spi_done, .spi_busy, .start, .abort_frame,
  .tx_empty, .rx_empty, .rx_full, .rx_pop, .rx_push, .events,
  .irq_status, .irq_enable, .irq_o
);

bind rp_axil_bridge rp_axil_properties axil_properties (
  .clk_i, .rst_ni, .bvalid_o, .bready_i, .bresp_o,
  .rvalid_o, .rready_i, .rresp_o, .rdata_o
);
