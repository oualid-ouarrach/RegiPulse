`default_nettype none

module regipulse_apb #(
    parameter int ADDR_WIDTH = 12,
    parameter int FIFO_DEPTH = 8,
    parameter int NUM_CS = 4
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  psel_i,
    input  logic                  penable_i,
    input  logic                  pwrite_i,
    input  logic [ADDR_WIDTH-1:0] paddr_i,
    input  logic [31:0]           pwdata_i,
    input  logic [3:0]            pstrb_i,
    output logic [31:0]           prdata_o,
    output logic                  pready_o,
    output logic                  pslverr_o,

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

    rp_apb_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) bridge (
        .rst_ni,
        .psel_i,
        .penable_i,
        .pwrite_i,
        .paddr_i,
        .pwdata_i,
        .pstrb_i,
        .prdata_o,
        .pready_o,
        .pslverr_o,
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
