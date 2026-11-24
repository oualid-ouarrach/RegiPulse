`timescale 1ns/1ps

// A pin-level SPI slave with its own transmit and receive words. It observes
// the actual CS selection and SCLK edges, and never reads DUT-internal state.
module rp_spi_target #(
  parameter integer NUM_CS = 4
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              sclk_i,
  input  logic              mosi_i,
  input  logic [NUM_CS-1:0] cs_ni,
  output logic              miso_o
);
  bit armed, active;
  bit cpol, cpha, lsb_first, expect_abort;
  logic [31:0] expected_mosi, response;
  logic [NUM_CS-1:0] selected;
  logic previous_sclk;
  integer frame_bits, half_cycles;
  integer cycle_number, last_edge, edge_count, bit_number;
  integer completed, aborted;

  function automatic logic serial_bit(input logic [31:0] word, input integer index);
    return word[lsb_first ? index : frame_bits - 1 - index];
  endfunction

  task automatic arm(
    input integer mode, input bit lsb, input integer length,
    input integer divider, input integer chip, input logic [31:0] tx_word,
    input logic [31:0] rx_word, input bit should_abort = 0
  );
    if (armed || active) $fatal(1, "%m target already armed or active");
    cpol = mode[1];
    cpha = mode[0];
    lsb_first = lsb;
    frame_bits = length;
    half_cycles = divider + 1;
    selected = '1;
    selected[chip] = 1'b0;
    expected_mosi = tx_word;
    response = rx_word;
    expect_abort = should_abort;
    armed = 1;
  endtask

  always @(posedge clk_i) begin
    // Observe outputs after the DUT's nonblocking updates. Drive MISO here
    // for the later sampling edge, whose minimum spacing is one core cycle.
    #1;
    if (!rst_ni) begin
      armed = 0;
      active = 0;
      cycle_number = 0;
      completed = 0;
      aborted = 0;
      miso_o = 0;
    end else begin
      cycle_number = cycle_number + 1;
      if (!active && cs_ni != '1) begin
        if (!armed || cs_ni !== selected || sclk_i !== cpol)
          $fatal(1, "%m invalid CS selection or idle clock at frame start");
        active = 1;
        last_edge = cycle_number;
        previous_sclk = cpol;
        edge_count = 0;
        if (!cpha) begin
          if (mosi_i !== serial_bit(expected_mosi, 0))
            $fatal(1, "%m CPHA=0 first MOSI bit was not ready at CS assertion");
          miso_o = serial_bit(response, 0);
        end
      end else if (active && cs_ni == '1) begin
        if (sclk_i !== cpol) $fatal(1, "%m SCLK did not return to idle");
        if (expect_abort) begin
          if (edge_count == 2 * frame_bits) $fatal(1, "%m frame completed before abort");
          aborted = aborted + 1;
        end else begin
          if (edge_count != 2 * frame_bits || cycle_number - last_edge != half_cycles)
            $fatal(1, "%m incorrect frame length or CS hold time, edges=%0d", edge_count);
          completed = completed + 1;
        end
        active = 0;
        armed = 0;
        miso_o = 0;
      end else if (active) begin
        if (cs_ni !== selected) $fatal(1, "%m chip select changed during frame");
        if (sclk_i !== previous_sclk) begin
          if (edge_count >= 2 * frame_bits || cycle_number - last_edge != half_cycles)
            $fatal(1, "%m unexpected clock edge, index=%0d", edge_count);
          bit_number = edge_count / 2;
          if (edge_count[0] == cpha && mosi_i !== serial_bit(expected_mosi, bit_number))
            $fatal(1, "%m MOSI mismatch at serial bit %0d, expected %b, got %b",
                   bit_number, serial_bit(expected_mosi, bit_number), mosi_i);
          if (cpha && !edge_count[0]) miso_o = serial_bit(response, bit_number);
          if (!cpha && edge_count[0] && bit_number + 1 < frame_bits)
            miso_o = serial_bit(response, bit_number + 1);
          edge_count = edge_count + 1;
          previous_sclk = sclk_i;
          last_edge = cycle_number;
        end else if (cycle_number - last_edge >= half_cycles) begin
          $fatal(1, "%m missing SCLK edge or CS release after edge %0d", edge_count);
        end
      end
    end
  end
endmodule

module tb_regipulse;
  localparam logic [11:0] CTRL = 12'h000, DIV = 12'h004, CMD = 12'h008,
    STATUS = 12'h00c, TXDATA = 12'h010, RXDATA = 12'h014, LEVEL = 12'h018,
    IRQ_STATUS = 12'h01c, IRQ_ENABLE = 12'h020, ID = 12'h024;
  localparam logic [31:0] DONE = 32'h01, TX_OVERFLOW = 32'h02, TX_UNDERFLOW = 32'h04,
    RX_OVERFLOW = 32'h08, RX_UNDERFLOW = 32'h10, ACCESS = 32'h20,
    CMD_ERROR = 32'h40, ABORTED = 32'h80;
  localparam logic [31:0] START = 32'h1, FLUSH_TX = 32'h2, FLUSH_RX = 32'h4,
    ABORT = 32'h8, ID_VALUE = 32'h5250_4701;
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;

  bit clk = 0;
  bit rst_n = 0;
  always #5 clk = ~clk;

  logic apb_psel = 0, apb_penable = 0, apb_pwrite = 0;
  logic [11:0] apb_paddr = '0;
  logic [31:0] apb_pwdata = '0, apb_prdata;
  logic [3:0] apb_pstrb = 0;
  logic apb_pready, apb_pslverr, apb_irq, apb_sclk, apb_mosi, apb_miso;
  logic [3:0] apb_csn;

  logic axi_awvalid = 0, axi_awready, axi_wvalid = 0, axi_wready;
  logic axi_bvalid, axi_bready = 0, axi_arvalid = 0, axi_arready;
  logic axi_rvalid, axi_rready = 0;
  logic [11:0] axi_awaddr = '0, axi_araddr = '0;
  logic [31:0] axi_wdata = '0, axi_rdata;
  logic [3:0] axi_wstrb = 0;
  logic [1:0] axi_bresp, axi_rresp;
  logic axi_irq, axi_sclk, axi_mosi, axi_miso;
  logic [3:0] axi_csn;

  regipulse_apb #(.ADDR_WIDTH(12), .FIFO_DEPTH(3), .NUM_CS(4)) dut_apb (
    .clk_i(clk), .rst_ni(rst_n), .psel_i(apb_psel), .penable_i(apb_penable),
    .pwrite_i(apb_pwrite), .paddr_i(apb_paddr), .pwdata_i(apb_pwdata),
    .pstrb_i(apb_pstrb), .prdata_o(apb_prdata), .pready_o(apb_pready),
    .pslverr_o(apb_pslverr), .irq_o(apb_irq), .sclk_o(apb_sclk),
    .mosi_o(apb_mosi), .miso_i(apb_miso), .cs_no(apb_csn)
  );

  regipulse_axil #(.ADDR_WIDTH(12), .FIFO_DEPTH(3), .NUM_CS(4)) dut_axil (
    .clk_i(clk), .rst_ni(rst_n),
    .awvalid_i(axi_awvalid), .awready_o(axi_awready), .awaddr_i(axi_awaddr), .awprot_i(3'b000),
    .wvalid_i(axi_wvalid), .wready_o(axi_wready), .wdata_i(axi_wdata), .wstrb_i(axi_wstrb),
    .bvalid_o(axi_bvalid), .bready_i(axi_bready), .bresp_o(axi_bresp),
    .arvalid_i(axi_arvalid), .arready_o(axi_arready), .araddr_i(axi_araddr), .arprot_i(3'b000),
    .rvalid_o(axi_rvalid), .rready_i(axi_rready), .rdata_o(axi_rdata), .rresp_o(axi_rresp),
    .irq_o(axi_irq), .sclk_o(axi_sclk), .mosi_o(axi_mosi), .miso_i(axi_miso), .cs_no(axi_csn)
  );

  rp_spi_target apb_target (.clk_i(clk), .rst_ni(rst_n), .sclk_i(apb_sclk),
    .mosi_i(apb_mosi), .cs_ni(apb_csn), .miso_o(apb_miso));
  rp_spi_target axi_target (.clk_i(clk), .rst_ni(rst_n), .sclk_i(axi_sclk),
    .mosi_i(axi_mosi), .cs_ni(axi_csn), .miso_o(axi_miso));

  task automatic scenario(input string name);
    $display("SCENARIO %s t_ns=%0d", name, $time);
  endtask

  task automatic checkpoint(input string name);
    $display("CHECKPOINT %s t_ns=%0d", name, $time);
  endtask

  function automatic logic [31:0] spi_config(
    input integer mode, input bit lsb, input integer length, input integer chip
  );
    return (chip << 8) | ((length - 1) << 3) | (32'(lsb) << 2) | ((mode & 1) << 1) | (mode >> 1);
  endfunction

  task automatic apb_setup(input bit write_access, input logic [11:0] addr,
                           input logic [31:0] data, input logic [3:0] strb);
    apb_psel = 1;
    apb_penable = 0;
    apb_pwrite = write_access;
    apb_paddr = addr;
    apb_pwdata = data;
    apb_pstrb = strb;
    #1;
    if (apb_pslverr !== 1'b0) $fatal(1, "APB PSLVERR asserted during setup");
  endtask

  task automatic apb_finish(input bit expected_err, output logic [31:0] result,
                            input bit retain_select = 0);
    apb_penable = 1;
    #1;
    if (apb_pready !== 1'b1 || apb_pslverr !== expected_err)
      $fatal(1, "APB addr=%h write=%b expected error=%b, got ready=%b error=%b",
             apb_paddr, apb_pwrite, expected_err, apb_pready, apb_pslverr);
    result = apb_prdata;
    @(negedge clk);
    apb_psel = retain_select;
    apb_penable = 0;
  endtask

  task automatic apb_wr(input logic [11:0] addr, input logic [31:0] data,
                        input logic [3:0] strb = 4'hf, input bit expected_err = 0);
    logic [31:0] unused_result;
    @(negedge clk);
    apb_setup(1, addr, data, strb);
    @(negedge clk);
    apb_finish(expected_err, unused_result);
  endtask

  task automatic apb_rd(input logic [11:0] addr, input logic [31:0] expected,
                        input bit expected_err = 0);
    logic [31:0] result;
    @(negedge clk);
    apb_setup(0, addr, '0, '0);
    @(negedge clk);
    apb_finish(expected_err, result);
    if (result !== expected)
      $fatal(1, "APB read %h expected %h, got %h", addr, expected, result);
  endtask

  task automatic apb_wait_event(input logic [31:0] event_mask);
    logic [31:0] result;
    integer tries;
    result = '0;
    tries = 0;
    while (tries < 400 && (result & event_mask) != event_mask) begin
      @(negedge clk);
      apb_setup(0, IRQ_STATUS, '0, '0);
      @(negedge clk);
      apb_finish(0, result);
      tries = tries + 1;
    end
    if ((result & event_mask) !== event_mask)
      $fatal(1, "APB timed out waiting for event mask %h", event_mask);
  endtask

  task automatic apb_spi_frame(
    input integer mode, input bit lsb, input integer length,
    input integer divider, input integer chip, input logic [31:0] tx_word,
    input logic [31:0] rx_word, input logic [3:0] tx_strb = 4'hf
  );
    integer frame_start;
    logic [31:0] expected_on_wire;
    expected_on_wire = '0;
    for (integer lane = 0; lane < 4; lane = lane + 1)
      if (tx_strb[lane]) expected_on_wire[lane*8 +: 8] = tx_word[lane*8 +: 8];
    apb_wr(CTRL, spi_config(mode, lsb, length, chip));
    apb_wr(DIV, 32'(divider));
    apb_wr(IRQ_STATUS, 32'hff);
    apb_wr(TXDATA, tx_word, tx_strb);
    apb_rd(LEVEL, 32'h1);
    if (apb_csn !== 4'hf || apb_sclk !== mode[1])
      $fatal(1, "APB idle SPI pins do not match new CPOL");
    frame_start = apb_target.completed;
    apb_target.arm(mode, lsb, length, divider, chip, expected_on_wire, rx_word);
    apb_wr(CMD, START);
    apb_wait_event(DONE);
    apb_rd(STATUS, 32'h2);
    apb_rd(LEVEL, 32'h100);
    apb_rd(RXDATA, rx_word);
    apb_rd(STATUS, 32'ha);
    if (apb_target.completed != frame_start + 1) $fatal(1, "APB expected one SPI frame");
  endtask

  task automatic apb_queue_frame(input logic [31:0] tx_word, input logic [31:0] rx_word);
    apb_wr(IRQ_STATUS, DONE);
    apb_target.arm(0, 0, 8, 1, 0, tx_word, rx_word);
    apb_wr(CMD, START);
    apb_wait_event(DONE);
  endtask

  // For a one-bit mode-0 frame with DIV=3, the final falling edge precedes
  // CS release by four core clocks. Set up APB in that gap and hit the exact
  // common-interface edge that consumes the SPI engine's completion pulse.
  task automatic apb_access_at_completion(
    input bit write_access, input logic [11:0] addr, input logic [31:0] data,
    output logic [31:0] result, input bit expected_err = 0
  );
    @(negedge apb_sclk);
    repeat (4) @(negedge clk);
    apb_setup(write_access, addr, data, write_access ? 4'hf : 4'h0);
    @(posedge apb_csn[0]);
    @(negedge clk);
    apb_finish(expected_err, result);
  endtask

  // Drive each request channel on its own schedule. Skew counts how many
  // clocks separate AW from W, with positive values launching AW first.
  task automatic axi_submit(
    input bit submit_aw, input bit submit_w, input bit submit_ar,
    input logic [11:0] addr, input logic [31:0] data = '0,
    input logic [3:0] strb = '0, input logic [11:0] read_addr = '0,
    input integer skew = 0
  );
    bit wait_aw, wait_w, wait_ar;
    integer aw_delay, w_delay, cycle_index;
    wait_aw = submit_aw;
    wait_w = submit_w;
    wait_ar = submit_ar;
    aw_delay = skew < 0 ? -skew : 0;
    w_delay = skew > 0 ? skew : 0;
    cycle_index = 0;
    while (wait_aw || wait_w || wait_ar) begin
      @(negedge clk);
      axi_awaddr = addr;
      axi_wdata = data;
      axi_wstrb = strb;
      axi_araddr = read_addr;
      axi_awvalid = wait_aw && cycle_index >= aw_delay;
      axi_wvalid = wait_w && cycle_index >= w_delay;
      axi_arvalid = wait_ar;
      @(posedge clk);
      if (axi_awvalid && axi_awready) wait_aw = 0;
      if (axi_wvalid && axi_wready) wait_w = 0;
      if (axi_arvalid && axi_arready) wait_ar = 0;
      cycle_index = cycle_index + 1;
    end
    @(negedge clk);
    axi_awvalid = 0;
    axi_wvalid = 0;
    axi_arvalid = 0;
  endtask

  task automatic take_b(input logic [1:0] expected_resp, input integer stall_cycles = 0);
    @(negedge clk);
    while (!axi_bvalid) @(negedge clk);
    repeat (stall_cycles) @(negedge clk);
    if (!axi_bvalid || axi_bresp !== expected_resp)
      $fatal(1, "AXI BRESP expected %b, got valid=%b resp=%b", expected_resp, axi_bvalid, axi_bresp);
    axi_bready = 1;
    @(negedge clk);
    axi_bready = 0;
  endtask

  task automatic take_r(input logic [1:0] expected_resp, output logic [31:0] result,
                        input integer stall_cycles = 0);
    @(negedge clk);
    while (!axi_rvalid) @(negedge clk);
    repeat (stall_cycles) @(negedge clk);
    if (!axi_rvalid || axi_rresp !== expected_resp)
      $fatal(1, "AXI RRESP expected %b, got valid=%b resp=%b", expected_resp, axi_rvalid, axi_rresp);
    result = axi_rdata;
    axi_rready = 1;
    @(negedge clk);
    axi_rready = 0;
  endtask

  task automatic axi_wr(input logic [11:0] addr, input logic [31:0] data,
                        input logic [3:0] strb = 4'hf, input logic [1:0] resp = OKAY,
                        input integer skew = 0, input integer stall_cycles = 0);
    axi_submit(1, 1, 0, addr, data, strb, '0, skew);
    take_b(resp, stall_cycles);
  endtask

  task automatic axi_rd(input logic [11:0] addr, input logic [31:0] expected,
                        input logic [1:0] resp = OKAY, input integer stall_cycles = 0);
    logic [31:0] result;
    axi_submit(0, 0, 1, '0, '0, '0, addr);
    take_r(resp, result, stall_cycles);
    if (result !== expected)
      $fatal(1, "AXI read %h expected %h, got %h", addr, expected, result);
  endtask

  task automatic axi_wait_event(input logic [31:0] event_mask);
    logic [31:0] result;
    integer tries;
    result = '0;
    tries = 0;
    while (tries < 400 && (result & event_mask) != event_mask) begin
      axi_submit(0, 0, 1, '0, '0, '0, IRQ_STATUS);
      take_r(OKAY, result);
      tries = tries + 1;
    end
    if ((result & event_mask) !== event_mask)
      $fatal(1, "AXI timed out waiting for event mask %h", event_mask);
  endtask

  // Protocol checks sample at the handshake edge, independently of the
  // driver tasks. Outstanding counts catch early and duplicate responses.
  integer aw_count, w_count, ar_count, b_count, r_count;
  bit previous_bstall, previous_rstall;
  logic [1:0] previous_bresp, previous_rresp;
  logic [31:0] previous_rdata;
  always @(posedge clk) begin
    if (!rst_n) begin
      aw_count <= 0;
      w_count <= 0;
      ar_count <= 0;
      b_count <= 0;
      r_count <= 0;
      previous_bstall <= 0;
      previous_rstall <= 0;
      previous_bresp <= '0;
      previous_rresp <= '0;
      previous_rdata <= '0;
    end else begin
      if (axi_bvalid && (aw_count <= b_count || w_count <= b_count))
        $fatal(1, "AXI BVALID without both AW and W handshakes");
      if (axi_rvalid && ar_count <= r_count) $fatal(1, "AXI RVALID without AR handshake");
      if (previous_bstall && (!axi_bvalid || axi_bresp !== previous_bresp))
        $fatal(1, "AXI B changed under backpressure");
      if (previous_rstall && (!axi_rvalid || {axi_rresp, axi_rdata} !== {previous_rresp, previous_rdata}))
        $fatal(1, "AXI R changed under backpressure");
      if (axi_awvalid && axi_awready) aw_count <= aw_count + 1;
      if (axi_wvalid && axi_wready) w_count <= w_count + 1;
      if (axi_arvalid && axi_arready) ar_count <= ar_count + 1;
      if (axi_bvalid && axi_bready) b_count <= b_count + 1;
      if (axi_rvalid && axi_rready) r_count <= r_count + 1;
      previous_bstall <= axi_bvalid && !axi_bready;
      previous_rstall <= axi_rvalid && !axi_rready;
      previous_bresp <= axi_bresp;
      previous_rresp <= axi_rresp;
      previous_rdata <= axi_rdata;
    end
  end

  task automatic reset_duts;
    @(negedge clk);
    rst_n = 0;
    repeat (3) @(negedge clk);
    #1;
    if ({apb_irq, axi_irq, apb_sclk, axi_sclk, apb_mosi, axi_mosi, axi_bvalid, axi_rvalid} !== 8'h00 ||
        {apb_csn, axi_csn} !== 8'hff) $fatal(1, "Reset did not clear IRQ, AXI responses or SPI pins");
    @(negedge clk);
    rst_n = 1;
  endtask

  initial begin : watchdog
    #100000;
    $fatal(1, "Directed regression watchdog expired");
  end

  initial begin : trace_setup
    string trace_path;
    if ($value$plusargs("vcd=%s", trace_path) || $test$plusargs("trace")) begin
      if (trace_path == "") trace_path = "build/regipulse.vcd";
      $dumpfile(trace_path);
      $dumpvars(0, tb_regipulse);
    end
  end

  initial begin : directed_regression
    logic [31:0] result;

    reset_duts();
    scenario("apb_register_access");
    apb_rd(CTRL, 32'h38);
    apb_rd(DIV, 32'h1);
    apb_rd(STATUS, 32'ha);
    apb_rd(LEVEL, 32'h0);
    apb_rd(IRQ_STATUS, 32'h0);
    apb_rd(IRQ_ENABLE, 32'h0);
    apb_rd(ID, ID_VALUE);

    checkpoint("apb_strobe_write");
    @(negedge clk);
    apb_setup(1, DIV, 32'hffff_00a5, 4'h1);
    @(negedge clk);
    apb_finish(0, result, 1);
    apb_setup(0, DIV, '0, '0);
    @(negedge clk);
    apb_finish(0, result);
    if (result !== 32'ha5) $fatal(1, "Back-to-back APB read missed previous write");
    apb_wr(DIV, 32'hff7f_1200, 4'h2);
    apb_wr(DIV, 32'hffff_ffff, 4'h0);
    apb_rd(DIV, 32'h12a5);
    apb_wr(DIV, 32'h0000_ffff);
    apb_rd(DIV, 32'h0000_ffff);
    apb_wr(DIV, 32'h1);
    apb_wr(CTRL, 32'hffff_013a, 4'h3);
    apb_rd(CTRL, 32'h13a);
    apb_wr(CMD, 32'h0000_0100, 4'h1);
    apb_wr(TXDATA, 32'hdead_beef, 4'h0);
    apb_rd(LEVEL, 32'h0);
    apb_rd(IRQ_STATUS, 32'h0);

    checkpoint("apb_unaligned_access");
    apb_rd(12'h025, 32'h0, 1);
    apb_rd(12'h124, 32'h0, 1);
    apb_rd(12'h028, 32'h0, 1);
    apb_rd(TXDATA, 32'h0, 1);
    apb_rd(CMD, 32'h0, 1);
    apb_wr(ID, '0, 4'hf, 1);
    apb_wr(STATUS, '0, 4'hf, 1);
    apb_wr(RXDATA, '0, 4'hf, 1);
    apb_rd(IRQ_STATUS, ACCESS);
    apb_wr(CTRL, 32'h438, 4'hf, 1);
    apb_wr(CTRL, 32'h1038, 4'hf, 1);
    apb_wr(DIV, 32'h0001_0001, 4'hf, 1);
    apb_wr(CMD, START | FLUSH_TX, 4'hf, 1);
    apb_wr(CMD, 32'h100, 4'hf, 1);
    apb_wr(CMD, ABORT, 4'hf, 1);
    apb_rd(IRQ_STATUS, ACCESS | CMD_ERROR);
    apb_rd(CTRL, 32'h13a);
    apb_rd(DIV, 32'h1);
    apb_wr(IRQ_STATUS, ACCESS | CMD_ERROR, 4'h2);
    apb_rd(IRQ_STATUS, ACCESS | CMD_ERROR);
    apb_wr(IRQ_STATUS, ACCESS, 4'h1);
    apb_rd(IRQ_STATUS, CMD_ERROR);
    apb_wr(IRQ_STATUS, CMD_ERROR, 4'h1);
    apb_rd(IRQ_STATUS, 0);

    scenario("apb_mode0");
    apb_spi_frame(0, 0, 8, 1, 0, 32'h0000_00a6, 32'h0000_003b);
    scenario("apb_mode1");
    apb_spi_frame(1, 1, 9, 2, 1, 32'h0000_01a7, 32'h0000_00cd);
    scenario("apb_mode2");
    apb_spi_frame(2, 1, 1, 0, 2, 32'h0000_0001, 32'h0000_0001);
    scenario("apb_mode3");
    apb_spi_frame(3, 0, 32, 0, 3, 32'h96ab_3f82, 32'hd526_84e7, 4'h9);

    scenario("apb_fifo_irq");
    apb_wr(IRQ_STATUS, '1);
    apb_wr(CMD, START, 4'hf, 1);
    apb_rd(RXDATA, '0, 1);
    apb_rd(IRQ_STATUS, TX_UNDERFLOW | RX_UNDERFLOW);
    if (apb_irq !== 1'b0) $fatal(1, "Masked error unexpectedly asserted IRQ");
    checkpoint("apb_irq_unmask");
    apb_wr(IRQ_ENABLE, TX_UNDERFLOW | RX_UNDERFLOW);
    if (apb_irq !== 1'b1) $fatal(1, "Unmasking pending errors did not assert IRQ");
    apb_wr(IRQ_STATUS, TX_UNDERFLOW);
    if (apb_irq !== 1'b1) $fatal(1, "W1C cleared an unrelated pending source");
    apb_rd(IRQ_STATUS, RX_UNDERFLOW);
    apb_wr(IRQ_ENABLE, TX_UNDERFLOW);
    if (apb_irq !== 1'b0) $fatal(1, "Masking the pending source did not deassert IRQ");
    apb_wr(IRQ_STATUS, RX_UNDERFLOW);
    apb_wr(IRQ_ENABLE, TX_OVERFLOW | RX_OVERFLOW | DONE);
    apb_wr(CTRL, spi_config(0, 0, 8, 0));
    apb_wr(DIV, 32'h1);
    apb_wr(TXDATA, 32'h81);
    apb_wr(TXDATA, 32'h42);
    apb_wr(TXDATA, 32'h24);
    apb_rd(STATUS, 32'hc);
    apb_rd(LEVEL, 32'h3);
    checkpoint("apb_tx_overflow");
    apb_wr(TXDATA, 32'hff, 4'hf, 1);
    apb_rd(IRQ_STATUS, TX_OVERFLOW);
    if (apb_irq !== 1'b1) $fatal(1, "TX_OVERFLOW did not assert IRQ");
    apb_wr(IRQ_STATUS, TX_OVERFLOW);
    if (apb_irq !== 1'b0) $fatal(1, "Clearing TX_OVERFLOW did not deassert IRQ");
    apb_queue_frame(32'h81, 32'h91);
    apb_wr(TXDATA, 32'h18); // Non-power-of-two TX ring wraps here.
    apb_queue_frame(32'h42, 32'h52);
    apb_queue_frame(32'h24, 32'h35);
    apb_rd(STATUS, 32'h10);
    apb_rd(LEVEL, 32'h301);
    checkpoint("apb_rx_overflow");
    apb_queue_frame(32'h18, 32'h73); // This response is dropped.
    apb_rd(STATUS, 32'h12);
    apb_rd(LEVEL, 32'h300);
    apb_rd(IRQ_STATUS, DONE | RX_OVERFLOW);
    apb_wr(IRQ_STATUS, DONE);
    if (apb_irq !== 1'b1) $fatal(1, "RX_OVERFLOW lost when DONE cleared");
    apb_wr(IRQ_STATUS, RX_OVERFLOW);
    if (apb_irq !== 1'b0) $fatal(1, "RX_OVERFLOW W1C did not deassert IRQ");
    apb_rd(RXDATA, 32'h91);
    apb_rd(RXDATA, 32'h52);
    apb_rd(RXDATA, 32'h35);
    apb_rd(LEVEL, 32'h0);
    apb_wr(TXDATA, 32'h81);
    apb_queue_frame(32'h81, 32'h91);
    apb_wr(TXDATA, 32'h17);
    apb_rd(LEVEL, 32'h101);
    apb_wr(CMD, FLUSH_TX);
    apb_rd(LEVEL, 32'h100);
    apb_wr(CMD, FLUSH_RX);
    apb_rd(LEVEL, 32'h0);

    scenario("apb_rx_full_pop");
    for (integer index = 0; index < 3; index = index + 1) begin
      apb_wr(TXDATA, 32'h13 + 32'(index));
      apb_queue_frame(32'h13 + 32'(index), 32'h23 + 32'(index));
    end
    apb_rd(LEVEL, 32'h300);
    apb_wr(IRQ_STATUS, '1);
    apb_wr(CTRL, spi_config(0, 0, 1, 0));
    apb_wr(DIV, 32'h3);
    apb_wr(TXDATA, 32'h0);
    apb_target.arm(0, 0, 1, 3, 0, 32'h0, 32'h1);
    apb_wr(CMD, START);
    apb_access_at_completion(0, RXDATA, '0, result);
    if (result !== 32'h23) $fatal(1, "Concurrent full RX pop did not return oldest word");
    apb_rd(LEVEL, 32'h300);
    apb_rd(IRQ_STATUS, DONE);
    apb_rd(RXDATA, 32'h24);
    apb_rd(RXDATA, 32'h25);
    apb_rd(RXDATA, 32'h1);
    apb_rd(LEVEL, 32'h0);

    scenario("apb_rx_empty_pop");
    apb_wr(IRQ_STATUS, '1);
    apb_wr(TXDATA, 32'h1);
    apb_target.arm(0, 0, 1, 3, 0, 32'h1, 32'h0);
    apb_wr(CMD, START);
    apb_access_at_completion(0, RXDATA, '0, result, 1);
    if (result !== 32'h0) $fatal(1, "Concurrent empty RX pop did not return zero");
    apb_rd(IRQ_STATUS, DONE | RX_UNDERFLOW);
    apb_rd(LEVEL, 32'h100);
    apb_rd(RXDATA, 32'h0);

    scenario("apb_done_w1c");
    apb_wr(IRQ_STATUS, '1);
    apb_wr(TXDATA, 32'h1);
    apb_target.arm(0, 0, 1, 3, 0, 32'h1, 32'h1);
    apb_wr(CMD, START);
    apb_access_at_completion(1, IRQ_STATUS, DONE, result);
    apb_rd(IRQ_STATUS, DONE);
    if (apb_irq !== 1'b1) $fatal(1, "Hardware DONE did not take priority over W1C");
    apb_wr(IRQ_STATUS, DONE);
    if (apb_irq !== 1'b0) $fatal(1, "DONE did not clear on a later W1C");
    apb_rd(RXDATA, 32'h1);

    scenario("apb_abort_reset");
    apb_wr(CTRL, spi_config(0, 0, 8, 0));
    apb_wr(DIV, 32'h1);
    apb_wr(TXDATA, 32'h51);
    apb_queue_frame(32'h51, 32'h32);
    apb_wr(IRQ_STATUS, DONE);
    apb_wr(CTRL, spi_config(3, 1, 32, 2));
    apb_wr(DIV, 32'h5);
    apb_wr(TXDATA, 32'h7ace_82a4);
    apb_target.arm(3, 1, 32, 5, 2, 32'h7ace_82a4, 32'h1, 1);
    apb_wr(CMD, START);
    apb_rd(STATUS, 32'h3);
    apb_wr(TXDATA, 32'h42);
    apb_rd(RXDATA, 32'h32);
    apb_rd(LEVEL, 32'h1);
    apb_wr(CMD, START, 4'hf, 1);
    apb_wr(CMD, FLUSH_TX, 4'hf, 1);
    apb_wr(CMD, FLUSH_RX, 4'hf, 1);
    apb_wr(CTRL, 32'h0, 4'hf, 1);
    apb_wr(DIV, 32'h0, 4'hf, 1);
    apb_wr(CMD, ABORT);
    apb_rd(IRQ_STATUS, CMD_ERROR | ABORTED);
    apb_rd(STATUS, 32'h8);
    apb_rd(LEVEL, 32'h1);
    apb_rd(CTRL, spi_config(3, 1, 32, 2));
    apb_rd(DIV, 32'h5);
    if (apb_target.aborted != 1) $fatal(1, "APB SPI abort was not observed on pins");
    apb_wr(CMD, FLUSH_TX);
    apb_spi_frame(0, 0, 8, 2, 0, 32'h61, 32'h71);
    apb_wr(CTRL, spi_config(3, 0, 32, 3));
    apb_wr(DIV, 32'h5);
    apb_wr(TXDATA, 32'hf0e1_d2c3);
    apb_wr(TXDATA, 32'h1);
    apb_target.arm(3, 0, 32, 5, 3, 32'hf0e1_d2c3, 32'h0);
    apb_wr(CMD, START);
    if (apb_csn !== 4'h7) $fatal(1, "APB reset test never started a frame");
    reset_duts();
    apb_rd(CTRL, 32'h38);
    apb_rd(DIV, 32'h1);
    apb_rd(STATUS, 32'ha);
    apb_rd(LEVEL, 32'h0);
    apb_rd(IRQ_ENABLE, '0);
    apb_rd(IRQ_STATUS, '0);
    apb_spi_frame(0, 0, 8, 1, 0, 32'h3a, 32'h75);

    scenario("axi_channels");
    axi_rd(ID, ID_VALUE);
    checkpoint("axi_aw_first");
    axi_wr(DIV, 32'h00a5, 4'h1, OKAY, 4, 5);
    checkpoint("axi_w_first");
    axi_wr(DIV, 32'h1200, 4'h2, OKAY, -3, 4);
    axi_rd(DIV, 32'h12a5, OKAY, 3);
    axi_wr(DIV, '1, 4'h0);
    axi_rd(DIV, 32'h12a5);
    checkpoint("axi_overlapping_channels");
    axi_submit(1, 1, 1, DIV, 32'h1, 4'hf, DIV);
    take_r(OKAY, result, 3);
    if (result !== 32'h1) $fatal(1, "AXI arbitration did not prefer write after read");
    take_b(OKAY, 5);
    axi_wr(DIV, 32'h2);
    axi_submit(1, 1, 1, DIV, 32'h1, 4'hf, DIV);
    take_b(OKAY, 3);
    take_r(OKAY, result, 5);
    if (result !== 32'h2) $fatal(1, "AXI arbitration did not prefer read after write");
    axi_rd(DIV, 32'h1);
    axi_rd(12'h025, '0, SLVERR, 3);
    axi_rd(12'h124, '0, SLVERR);
    axi_wr(12'h028, '0, 4'hf, SLVERR, 3, 2);
    axi_rd(TXDATA, '0, SLVERR);
    axi_wr(ID, '0, 4'hf, SLVERR);
    axi_rd(IRQ_STATUS, ACCESS);
    axi_wr(IRQ_STATUS, ACCESS, 4'h1);
    axi_rd(IRQ_STATUS, '0);

    scenario("axi_spi");
    axi_wr(CTRL, spi_config(1, 1, 12, 1));
    axi_wr(DIV, 32'h2);
    axi_wr(IRQ_ENABLE, DONE);
    axi_wr(TXDATA, 32'h953, 4'hf, OKAY, -4);
    axi_rd(LEVEL, 32'h1);
    axi_target.arm(1, 1, 12, 2, 1, 32'h953, 32'h384);
    axi_wr(CMD, START);
    axi_wait_event(DONE);
    if (axi_target.completed != 1 || axi_irq !== 1'b1)
      $fatal(1, "AXI SPI frame or completion interrupt missing");
    axi_rd(RXDATA, 32'h384, OKAY, 7);
    axi_rd(LEVEL, '0);
    axi_rd(RXDATA, '0, SLVERR);
    axi_rd(IRQ_STATUS, DONE | RX_UNDERFLOW);
    axi_wr(IRQ_STATUS, DONE);
    if (axi_irq !== 1'b0) $fatal(1, "AXI masked RX_UNDERFLOW asserted IRQ");

    scenario("axi_reset");
    axi_submit(1, 1, 1, TXDATA, 32'h1234_5678, 4'hf, ID);
    wait (axi_bvalid && axi_rvalid);
    reset_duts();
    axi_rd(LEVEL, '0);
    axi_rd(IRQ_STATUS, '0);
    axi_submit(1, 0, 0, TXDATA); // Reset must discard AW waiting for W.
    if (axi_bvalid) $fatal(1, "AXI responded to an AW-only fragment");
    reset_duts();
    axi_wr(DIV, 32'h8, 4'hf, OKAY, -3, 3);
    axi_rd(DIV, 32'h8);
    axi_rd(LEVEL, '0);
    axi_submit(0, 1, 0, '0, 32'h1122_3344, 4'hf); // Repeat for a W-only fragment.
    if (axi_bvalid) $fatal(1, "AXI responded to a W-only fragment");
    reset_duts();
    axi_wr(DIV, 32'h9, 4'hf, OKAY, 3, 3);
    axi_rd(DIV, 32'h9);
    axi_rd(LEVEL, '0);
    if (aw_count != b_count || w_count != b_count || ar_count != r_count)
      $fatal(1, "AXI reset recovery left an outstanding transaction");

    $display("PASS tb_regipulse directed integration");
    $finish;
  end
endmodule
