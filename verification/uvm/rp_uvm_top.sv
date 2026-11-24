module rp_uvm_top;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import rp_apb_smoke_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic sclk, mosi, miso;
  logic [3:0] cs_n;
  int completed_frames = 0;

  rp_apb_if apb (clk, rst_n);
  regipulse_apb dut (
    .clk_i(clk), .rst_ni(rst_n), .psel_i(apb.sel), .penable_i(apb.enable),
    .pwrite_i(apb.write), .paddr_i(apb.addr), .pwdata_i(apb.wdata),
    .pstrb_i(apb.strb), .prdata_o(apb.rdata), .pready_o(apb.ready),
    .pslverr_o(apb.error), .irq_o(apb.irq), .sclk_o(sclk), .mosi_o(mosi),
    .cs_no(cs_n), .miso_i(miso)
  );

  always #5ns clk = ~clk;
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
  end

  // Independent mode-0 slave. Sample each MOSI bit on a rising wire edge.
  // Drive the next MISO bit only after the corresponding falling edge.
  initial begin : spi_slave
    localparam logic [7:0] RESPONSE = 8'h3d;
    logic [7:0] captured;

    miso = 1'b0;
    wait (rst_n);
    @(negedge cs_n[0]);
    if (cs_n !== 4'b1110 || sclk !== 1'b0)
      $fatal(1, "Unexpected CS or idle SCLK at SPI frame start");
    for (int index = 7; index >= 0; index--) begin
      miso = RESPONSE[index];
      @(posedge sclk);
      if (cs_n !== 4'b1110)
        $fatal(1, "SPI chip select changed before the sample edge");
      captured[index] = mosi;
      @(negedge sclk);
    end
    @(posedge cs_n[0]);
    if (captured !== 8'ha6 || sclk !== 1'b0 || cs_n !== 4'b1111)
      $fatal(1, "SPI pin check failed, captured 0x%02h", captured);
    completed_frames++;
    $display("SPI slave captured 0x%02h and returned 0x%02h", captured, RESPONSE);
  end

  initial begin
    uvm_report_server server;
    uvm_config_db#(virtual rp_apb_if)::set(null, "uvm_test_top*", "vif", apb);
    uvm_root::get().set_finish_on_completion(0);
    run_test("rp_apb_smoke_test");
    server = uvm_report_server::get_server();
    if (server.get_severity_count(UVM_ERROR) != 0 ||
        server.get_severity_count(UVM_FATAL) != 0 || completed_frames != 1)
      $fatal(1, "RegiPulse APB UVM smoke failed");
    $display("PASS RegiPulse APB UVM smoke");
    $finish;
  end

  initial begin
    #10us;
    $fatal(1, "RegiPulse APB UVM smoke timed out");
  end
endmodule
