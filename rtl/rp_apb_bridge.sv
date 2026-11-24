`default_nettype none

module rp_apb_bridge #(
    parameter int ADDR_WIDTH = 12
) (
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

    output logic                  req_valid_o,
    output logic                  req_write_o,
    output logic [ADDR_WIDTH-1:0] req_addr_o,
    output logic [31:0]           req_wdata_o,
    output logic [3:0]            req_wstrb_o,
    input  logic [31:0]           rsp_rdata_i,
    input  logic                  rsp_err_i
);
    // The common register interface completes in the access phase.
    assign pready_o    = 1'b1;
    assign req_valid_o = rst_ni && psel_i && penable_i;
    assign req_write_o = pwrite_i;
    assign req_addr_o  = paddr_i;
    assign req_wdata_o = pwdata_i;
    assign req_wstrb_o = pwrite_i ? pstrb_i : 4'b0000;
    assign prdata_o    = req_valid_o && !pwrite_i ? rsp_rdata_i : 32'b0;
    assign pslverr_o   = req_valid_o && rsp_err_i;
endmodule

`default_nettype wire
