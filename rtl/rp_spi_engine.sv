`default_nettype none

module rp_spi_engine #(
    parameter integer NUM_CS = 4
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  logic                start_i,
    input  logic                abort_i,
    input  logic                cpol_i,
    input  logic                cpha_i,
    input  logic                lsb_first_i,
    input  logic [4:0]          bits_minus_one_i,
    input  logic [3:0]          cs_index_i,
    input  logic [15:0]         divider_i,
    input  logic [31:0]         tx_data_i,
    output logic                busy_o,
    output logic                done_o,
    output logic [31:0]         rx_data_o,
    output logic                sclk_o,
    output logic                mosi_o,
    output logic [NUM_CS-1:0]   cs_no,
    input  logic                miso_i
);
    typedef enum logic [1:0] {IDLE, SHIFT, HOLD_CS} state_t;

    state_t state_q;
    logic cpol_q, cpha_q, lsb_first_q;
    logic sclk_q, leading_edge_q;
    logic [4:0] bit_index_q, next_bit_index, remaining_q;
    logic [15:0] divider_q, half_count_q;
    logic [31:0] tx_q, rx_q;

    // Keep the chip selects and active SCLK path independent of the FSM decode.
    assign sclk_o = busy_o ? sclk_q : cpol_i;
    assign next_bit_index = lsb_first_q ? bit_index_q + 1'b1 : bit_index_q - 1'b1;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q          <= IDLE;
            cpol_q           <= 1'b0;
            cpha_q           <= 1'b0;
            lsb_first_q      <= 1'b0;
            sclk_q           <= 1'b0;
            leading_edge_q   <= 1'b1;
            bit_index_q      <= '0;
            remaining_q      <= '0;
            divider_q        <= '0;
            half_count_q     <= '0;
            tx_q             <= '0;
            rx_q             <= '0;
            cs_no            <= '1;
            busy_o           <= 1'b0;
            done_o           <= 1'b0;
            rx_data_o        <= '0;
            mosi_o           <= 1'b0;
        end else begin
            done_o <= 1'b0;

            if (abort_i) begin
                state_q <= IDLE;
                sclk_q  <= cpol_i;
                cs_no   <= '1;
                busy_o  <= 1'b0;
                mosi_o  <= 1'b0;
            end else begin
                case (state_q)
                    IDLE: begin
                        sclk_q <= cpol_i;
                        if (start_i && ({1'b0, cs_index_i} < 5'(NUM_CS))) begin
                            state_q         <= SHIFT;
                            cpol_q          <= cpol_i;
                            cpha_q          <= cpha_i;
                            lsb_first_q     <= lsb_first_i;
                            leading_edge_q  <= 1'b1;
                            bit_index_q     <= lsb_first_i ? 5'd0 : bits_minus_one_i;
                            remaining_q     <= bits_minus_one_i;
                            divider_q       <= divider_i;
                            half_count_q    <= divider_i;
                            tx_q            <= tx_data_i;
                            rx_q            <= '0;
                            cs_no           <= ~(NUM_CS'(1) << cs_index_i);
                            busy_o          <= 1'b1;
                            if (!cpha_i)
                                mosi_o <= tx_data_i[lsb_first_i ? 5'd0 : bits_minus_one_i];
                        end
                    end

                    SHIFT: begin
                        if (half_count_q != 0) begin
                            half_count_q <= half_count_q - 1'b1;
                        end else begin
                            half_count_q   <= divider_q;
                            leading_edge_q <= !leading_edge_q;

                            if (leading_edge_q) begin
                                sclk_q <= !cpol_q;
                                if (cpha_q)
                                    mosi_o <= tx_q[bit_index_q];
                                else
                                    rx_q[bit_index_q] <= miso_i;
                            end else begin
                                sclk_q <= cpol_q;
                                if (cpha_q)
                                    rx_q[bit_index_q] <= miso_i;

                                if (remaining_q == 0) begin
                                    state_q <= HOLD_CS;
                                end else begin
                                    remaining_q <= remaining_q - 1'b1;
                                    bit_index_q <= next_bit_index;
                                    if (!cpha_q)
                                        mosi_o <= tx_q[next_bit_index];
                                end
                            end
                        end
                    end

                    HOLD_CS: begin
                        // Keep CS active for one half-period after the final trailing edge.
                        if (half_count_q != 0) begin
                            half_count_q <= half_count_q - 1'b1;
                        end else begin
                            state_q   <= IDLE;
                            cs_no     <= '1;
                            busy_o    <= 1'b0;
                            done_o    <= 1'b1;
                            rx_data_o <= rx_q;
                            mosi_o    <= 1'b0;
                        end
                    end

                    default: begin
                        state_q <= IDLE;
                        sclk_q  <= cpol_i;
                        cs_no   <= '1;
                        busy_o  <= 1'b0;
                        mosi_o  <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
