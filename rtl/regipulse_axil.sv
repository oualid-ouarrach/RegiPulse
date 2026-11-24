`default_nettype none

module regipulse_axil #(
    parameter int ADDR_WIDTH = 12,
    parameter int FIFO_DEPTH = 8,
    parameter int NUM_CS = 4
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  awvalid_i,
    output logic                  awready_o,
    input  logic [ADDR_WIDTH-1:0] awaddr_i,
    input  logic [2:0]            awprot_i,
    input  logic                  wvalid_i,
    output logic                  wready_o,
    input  logic [31:0]           wdata_i,
    input  logic [3:0]            wstrb_i,
    output logic                  bvalid_o,
    input  logic                  bready_i,
    output logic [1:0]            bresp_o,
    input  logic                  arvalid_i,
    output logic                  arready_o,
    input  logic [ADDR_WIDTH-1:0] araddr_i,
    input  logic [2:0]            arprot_i,
    output logic                  rvalid_o,
    input  logic                  rready_i,
    output logic [31:0]           rdata_o,
    output logic [1:0]            rresp_o,

    output logic                  irq_o,
    output logic                  sclk_o,
    output logic                  mosi_o,
    output logic [NUM_CS-1:0]     cs_no,
    input  logic                  miso_i
);
    logic req_valid, req_write, rsp_err;
    logic [ADDR_WIDTH-1:0] req_addr;
    logic [31:0] req_wdata, rsp_rdata;
    logic [3:0] req_wstrb;

    rp_axil_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) bridge (
        .clk_i,
        .rst_ni,
        .awvalid_i,
        .awready_o,
        .awaddr_i,
        .awprot_i,
        .wvalid_i,
        .wready_o,
        .wdata_i,
        .wstrb_i,
        .bvalid_o,
        .bready_i,
        .bresp_o,
        .arvalid_i,
        .arready_o,
        .araddr_i,
        .arprot_i,
        .rvalid_o,
        .rready_i,
        .rdata_o,
        .rresp_o,
        .req_valid_o(req_valid),
        .req_write_o(req_write),
        .req_addr_o(req_addr),
        .req_wdata_o(req_wdata),
        .req_wstrb_o(req_wstrb),
        .rsp_rdata_i(rsp_rdata),
        .rsp_err_i(rsp_err)
    );

    regipulse_core #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .NUM_CS(NUM_CS)
    ) core (
        .clk_i,
        .rst_ni,
        .req_valid_i(req_valid),
        .req_write_i(req_write),
        .req_addr_i(req_addr),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .rsp_rdata_o(rsp_rdata),
        .rsp_err_o(rsp_err),
        .irq_o,
        .sclk_o,
        .mosi_o,
        .cs_no,
        .miso_i
    );
endmodule

`default_nettype wire
