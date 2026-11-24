`default_nettype none

module rp_axil_bridge #(
    parameter int ADDR_WIDTH = 12
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

    output logic                  req_valid_o,
    output logic                  req_write_o,
    output logic [ADDR_WIDTH-1:0] req_addr_o,
    output logic [31:0]           req_wdata_o,
    output logic [3:0]            req_wstrb_o,
    input  logic [31:0]           rsp_rdata_i,
    input  logic                  rsp_err_i
);
    localparam logic [1:0] RESP_OKAY = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    logic aw_pending_q, w_pending_q, ar_pending_q;
    logic [ADDR_WIDTH-1:0] awaddr_q, araddr_q;
    logic [31:0] wdata_q;
    logic [3:0] wstrb_q;
    logic bvalid_q, rvalid_q;
    logic write_pending, write_grant, read_grant;
    logic prefer_read_q;
    logic unused_prot;

    // The same register permissions apply to every AXI protection encoding.
    assign unused_prot = ^{awprot_i, arprot_i};

    // Each direction holds one transaction until its response is accepted.
    // The response for either direction can stall without blocking the other.
    assign awready_o = rst_ni && !aw_pending_q && !bvalid_q;
    assign wready_o  = rst_ni && !w_pending_q && !bvalid_q;
    assign arready_o = rst_ni && !ar_pending_q && !rvalid_q;
    assign bvalid_o  = rst_ni && bvalid_q;
    assign rvalid_o  = rst_ni && rvalid_q;

    assign write_pending = aw_pending_q && w_pending_q;
    assign write_grant   = rst_ni && write_pending && (!ar_pending_q || !prefer_read_q);
    assign read_grant    = rst_ni && ar_pending_q && (!write_pending || prefer_read_q);

    assign req_valid_o = write_grant || read_grant;
    assign req_write_o = write_grant;
    assign req_addr_o  = write_grant ? awaddr_q : araddr_q;
    assign req_wdata_o = wdata_q;
    assign req_wstrb_o = write_grant ? wstrb_q : 4'b0000;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            aw_pending_q  <= 1'b0;
            w_pending_q   <= 1'b0;
            ar_pending_q  <= 1'b0;
            awaddr_q      <= '0;
            wdata_q       <= '0;
            wstrb_q       <= '0;
            araddr_q      <= '0;
            bvalid_q      <= 1'b0;
            bresp_o       <= RESP_OKAY;
            rvalid_q      <= 1'b0;
            rdata_o       <= '0;
            rresp_o       <= RESP_OKAY;
            prefer_read_q <= 1'b0;
        end else begin
            if (awvalid_i && awready_o) begin
                aw_pending_q <= 1'b1;
                awaddr_q     <= awaddr_i;
            end
            if (wvalid_i && wready_o) begin
                w_pending_q <= 1'b1;
                wdata_q     <= wdata_i;
                wstrb_q     <= wstrb_i;
            end
            if (arvalid_i && arready_o) begin
                ar_pending_q <= 1'b1;
                araddr_q     <= araddr_i;
            end

            if (bvalid_q && bready_i)
                bvalid_q <= 1'b0;
            if (rvalid_q && rready_i)
                rvalid_q <= 1'b0;

            if (write_grant) begin
                aw_pending_q  <= 1'b0;
                w_pending_q   <= 1'b0;
                bvalid_q      <= 1'b1;
                bresp_o       <= rsp_err_i ? RESP_SLVERR : RESP_OKAY;
                prefer_read_q <= 1'b1;
            end
            if (read_grant) begin
                ar_pending_q  <= 1'b0;
                rvalid_q      <= 1'b1;
                rdata_o       <= rsp_rdata_i;
                rresp_o       <= rsp_err_i ? RESP_SLVERR : RESP_OKAY;
                prefer_read_q <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
