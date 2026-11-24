`default_nettype none

module rp_fifo #(
    parameter integer DEPTH = 8,
    parameter integer WIDTH = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         clear_i,
    input  logic                         push_i,
    input  logic                         pop_i,
    input  logic [WIDTH-1:0]             push_data_i,
    output logic [WIDTH-1:0]             pop_data_o,
    output logic                         empty_o,
    output logic                         full_o,
    output logic [$clog2(DEPTH+1)-1:0]   level_o
);
    localparam integer PTR_WIDTH = (DEPTH == 1) ? 1 : $clog2(DEPTH);
    localparam integer LEVEL_WIDTH = $clog2(DEPTH+1);

    logic [WIDTH-1:0] storage_q [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] read_ptr_q, write_ptr_q;
    logic [LEVEL_WIDTH-1:0] count_q;
    logic push_accepted, pop_accepted;

    assign empty_o = (count_q == 0);
    assign full_o = (count_q == LEVEL_WIDTH'(DEPTH));
    assign level_o = count_q;
    assign pop_data_o = empty_o ? '0 : storage_q[read_ptr_q];

    // An empty FIFO has no data to pop. A pop from a full FIFO makes room for a push.
    assign pop_accepted = pop_i && !empty_o;
    assign push_accepted = push_i && (!full_o || pop_accepted);

    always_ff @(posedge clk_i) begin
        if (rst_ni && !clear_i && push_accepted)
            storage_q[write_ptr_q] <= push_data_i;
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni || clear_i) begin
            read_ptr_q  <= '0;
            write_ptr_q <= '0;
            count_q     <= '0;
        end else begin
            if (pop_accepted)
                read_ptr_q <= (read_ptr_q == PTR_WIDTH'(DEPTH-1)) ? '0 : read_ptr_q + 1'b1;
            if (push_accepted)
                write_ptr_q <= (write_ptr_q == PTR_WIDTH'(DEPTH-1)) ? '0 : write_ptr_q + 1'b1;

            case ({push_accepted, pop_accepted})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: begin end
            endcase
        end
    end
endmodule

`default_nettype wire
