module regipulse_core #(
  parameter integer ADDR_WIDTH = 12,
  parameter integer FIFO_DEPTH = 8,
  parameter integer NUM_CS = 4
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  logic                  req_valid_i,
  input  logic                  req_write_i,
  input  logic [ADDR_WIDTH-1:0] req_addr_i,
  input  logic [31:0]           req_wdata_i,
  input  logic [3:0]            req_wstrb_i,
  output logic [31:0]           rsp_rdata_o,
  output logic                  rsp_err_o,
  output logic                  irq_o,
  output logic                  sclk_o,
  output logic                  mosi_o,
  output logic [NUM_CS-1:0]     cs_no,
  input  logic                  miso_i
);

  localparam integer LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1);

  localparam logic [ADDR_WIDTH-1:0] AddrCtrl       = 'h00;
  localparam logic [ADDR_WIDTH-1:0] AddrDiv        = 'h04;
  localparam logic [ADDR_WIDTH-1:0] AddrCmd        = 'h08;
  localparam logic [ADDR_WIDTH-1:0] AddrStatus     = 'h0c;
  localparam logic [ADDR_WIDTH-1:0] AddrTxData     = 'h10;
  localparam logic [ADDR_WIDTH-1:0] AddrRxData     = 'h14;
  localparam logic [ADDR_WIDTH-1:0] AddrLevel      = 'h18;
  localparam logic [ADDR_WIDTH-1:0] AddrIrqStatus  = 'h1c;
  localparam logic [ADDR_WIDTH-1:0] AddrIrqEnable  = 'h20;
  localparam logic [ADDR_WIDTH-1:0] AddrId         = 'h24;

  localparam integer EventDone        = 0;
  localparam integer EventTxOverflow  = 1;
  localparam integer EventTxUnderflow = 2;
  localparam integer EventRxOverflow  = 3;
  localparam integer EventRxUnderflow = 4;
  localparam integer EventAccess      = 5;
  localparam integer EventCommand     = 6;
  localparam integer EventAborted     = 7;

  logic [11:0] ctrl_q;
  logic [15:0] divider_q;
  logic [31:0] byte_mask, write_data, ctrl_next, divider_next;
  logic        ctrl_we, divider_we;

  logic [7:0] irq_status, irq_enable, irq_clear, events;
  logic       irq_enable_we;
  logic [7:0] irq_enable_data;

  logic [31:0] tx_head, rx_head, rx_frame;
  logic [LEVEL_WIDTH-1:0] tx_level, rx_level;
  logic        tx_empty, tx_full, rx_empty, rx_full;
  logic        tx_push, rx_pop, tx_clear, rx_clear, rx_push;
  logic        start, abort_frame, spi_busy, spi_done, busy;

  assign byte_mask = {{8{req_wstrb_i[3]}}, {8{req_wstrb_i[2]}},
                      {8{req_wstrb_i[1]}}, {8{req_wstrb_i[0]}}};
  assign write_data = req_wdata_i & byte_mask;
  assign ctrl_next = ({20'b0, ctrl_q} & ~byte_mask) | write_data;
  assign divider_next = ({16'b0, divider_q} & ~byte_mask) | write_data;
  assign irq_enable_data = (irq_enable & ~byte_mask[7:0]) | write_data[7:0];

  // Keep BUSY set until the completed word and its events are visible together.
  assign busy = spi_busy | spi_done;
  assign rx_push = spi_done && (!rx_full || rx_pop);

  rp_fifo #(.DEPTH(FIFO_DEPTH), .WIDTH(32)) tx_fifo (
    .clk_i, .rst_ni, .clear_i(tx_clear), .push_i(tx_push), .pop_i(start),
    .push_data_i(write_data), .pop_data_o(tx_head), .empty_o(tx_empty),
    .full_o(tx_full), .level_o(tx_level)
  );

  rp_fifo #(.DEPTH(FIFO_DEPTH), .WIDTH(32)) rx_fifo (
    .clk_i, .rst_ni, .clear_i(rx_clear), .push_i(rx_push), .pop_i(rx_pop),
    .push_data_i(rx_frame), .pop_data_o(rx_head), .empty_o(rx_empty),
    .full_o(rx_full), .level_o(rx_level)
  );

  rp_spi_engine #(.NUM_CS(NUM_CS)) spi_engine (
    .clk_i, .rst_ni, .start_i(start), .abort_i(abort_frame),
    .cpol_i(ctrl_q[0]), .cpha_i(ctrl_q[1]), .lsb_first_i(ctrl_q[2]),
    .bits_minus_one_i(ctrl_q[7:3]), .cs_index_i(ctrl_q[11:8]), .divider_i(divider_q),
    .tx_data_i(tx_head), .busy_o(spi_busy), .done_o(spi_done), .rx_data_o(rx_frame),
    .sclk_o, .mosi_o, .cs_no, .miso_i
  );

  rp_irq irq_control (
    .clk_i, .rst_ni, .events_i(events), .clear_i(irq_clear),
    .enable_write_i(irq_enable_we), .enable_data_i(irq_enable_data),
    .status_o(irq_status), .enable_o(irq_enable), .irq_o
  );

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      ctrl_q <= 12'h038;
      divider_q <= 16'd1;
    end else begin
      if (ctrl_we) begin
        ctrl_q <= ctrl_next[11:0];
      end
      if (divider_we) begin
        divider_q <= divider_next[15:0];
      end
    end
  end

  always_comb begin
    rsp_rdata_o = '0;
    rsp_err_o = 1'b0;
    events = '0;
    irq_clear = '0;
    irq_enable_we = 1'b0;
    ctrl_we = 1'b0;
    divider_we = 1'b0;
    tx_push = 1'b0;
    rx_pop = 1'b0;
    tx_clear = 1'b0;
    rx_clear = 1'b0;
    start = 1'b0;
    abort_frame = 1'b0;

    if (rst_ni && req_valid_i) begin
      if (req_write_i) begin
        case (req_addr_i)
          AddrCtrl: begin
            if (|req_wstrb_i) begin
              if (busy || (|ctrl_next[31:12]) || (int'(ctrl_next[11:8]) >= NUM_CS)) begin
                events[EventCommand] = 1'b1;
              end else begin
                ctrl_we = 1'b1;
              end
            end
          end
          AddrDiv: begin
            if (|req_wstrb_i) begin
              if (busy || (|divider_next[31:16])) begin
                events[EventCommand] = 1'b1;
              end else begin
                divider_we = 1'b1;
              end
            end
          end
          AddrCmd: begin
            case (write_data)
              32'd0: begin end
              32'd1: begin
                if (busy) begin
                  events[EventCommand] = 1'b1;
                end else if (tx_empty) begin
                  events[EventTxUnderflow] = 1'b1;
                end else begin
                  start = 1'b1;
                end
              end
              32'd2: begin
                if (busy) begin
                  events[EventCommand] = 1'b1;
                end else begin
                  tx_clear = 1'b1;
                end
              end
              32'd4: begin
                if (busy) begin
                  events[EventCommand] = 1'b1;
                end else begin
                  rx_clear = 1'b1;
                end
              end
              32'd8: begin
                if (spi_busy) begin
                  abort_frame = 1'b1;
                  events[EventAborted] = 1'b1;
                end else begin
                  events[EventCommand] = 1'b1;
                end
              end
              default: events[EventCommand] = 1'b1;
            endcase
          end
          AddrTxData: begin
            if (|req_wstrb_i) begin
              if (tx_full) begin
                events[EventTxOverflow] = 1'b1;
              end else begin
                tx_push = 1'b1;
              end
            end
          end
          AddrIrqStatus: irq_clear = write_data[7:0];
          AddrIrqEnable: irq_enable_we = req_wstrb_i[0];
          default: events[EventAccess] = 1'b1;
        endcase
      end else begin
        case (req_addr_i)
          AddrCtrl:      rsp_rdata_o = {20'b0, ctrl_q};
          AddrDiv:       rsp_rdata_o = {16'b0, divider_q};
          AddrStatus:    rsp_rdata_o = {27'b0, rx_full, rx_empty, tx_full, tx_empty, busy};
          AddrRxData: begin
            if (rx_empty) begin
              events[EventRxUnderflow] = 1'b1;
            end else begin
              rsp_rdata_o = rx_head;
              rx_pop = 1'b1;
            end
          end
          AddrLevel:     rsp_rdata_o = {16'b0, 8'(rx_level), 8'(tx_level)};
          AddrIrqStatus: rsp_rdata_o = {24'b0, irq_status};
          AddrIrqEnable: rsp_rdata_o = {24'b0, irq_enable};
          AddrId:        rsp_rdata_o = 32'h5250_4701;
          default:       events[EventAccess] = 1'b1;
        endcase
      end
    end

    events[EventDone] = spi_done;
    events[EventRxOverflow] = spi_done && rx_full && !rx_pop;
    rsp_err_o = events[EventTxOverflow] || events[EventTxUnderflow] ||
                events[EventRxUnderflow] || events[EventAccess] || events[EventCommand];
  end

endmodule
