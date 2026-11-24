`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module rp_fifo_check #(
    parameter integer DEPTH = 1
) (
    input logic clk_i,
    output logic complete_o = 1'b0
);
    localparam integer LEVEL_WIDTH = $clog2(DEPTH+1);

    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic push = 1'b0;
    logic pop = 1'b0;
    logic [31:0] data_in = '0;
    logic [31:0] head;
    logic empty, full;
    logic [LEVEL_WIDTH-1:0] level;
    logic [31:0] expected [0:DEPTH-1];
    integer count = 0;

    rp_fifo #(.DEPTH(DEPTH)) dut (
        .clk_i, .rst_ni(rst_n), .clear_i(clear), .push_i(push), .pop_i(pop),
        .push_data_i(data_in), .pop_data_o(head), .empty_o(empty), .full_o(full), .level_o(level)
    );

    task automatic check_state;
        logic [31:0] expected_head;
        expected_head = (count == 0) ? '0 : expected[0];
        if (level !== LEVEL_WIDTH'(count) || empty !== (count == 0) || full !== (count == DEPTH))
            $fatal(1, "FIFO depth %0d: level/flags mismatch at expected level %0d", DEPTH, count);
        if (head !== expected_head)
            $fatal(1, "FIFO depth %0d: head was %h, expected %h", DEPTH, head, expected_head);
    endtask

    task automatic fifo_step(input bit do_clear, do_push, do_pop, input logic [31:0] data);
        @(negedge clk_i);
        rst_n = 1'b1;
        clear = do_clear;
        push = do_push;
        pop = do_pop;
        data_in = data;
        check_state();

        if (do_clear) begin
            count = 0;
        end else begin
            if (do_pop && count != 0) begin
                for (integer index = 0; index < count-1; index++)
                    expected[index] = expected[index+1];
                count--;
            end
            if (do_push && count < DEPTH) begin
                expected[count] = data;
                count++;
            end
        end

        @(posedge clk_i);
        #1;
        check_state();
    endtask

    initial begin
        @(posedge clk_i);
        #1;
        check_state();

        fifo_step(0, 0, 1, '0);
        fifo_step(0, 1, 1, 32'h1122_3344);
        fifo_step(0, 0, 1, '0);
        for (integer word = 0; word < DEPTH; word++)
            fifo_step(0, 1, 0, 32'h1000_0000 + word);
        fifo_step(0, 1, 0, 32'hbad0_face);
        for (integer word = 0; word < 2*DEPTH + 1; word++)
            fifo_step(0, 1, 1, 32'h2000_0000 + word);
        for (integer word = 0; word < DEPTH; word++)
            fifo_step(0, 0, 1, '0);
        fifo_step(0, 1, 0, 32'habcd_1234);
        fifo_step(1, 1, 1, 32'hdead_beef);
        fifo_step(0, 1, 0, 32'h0123_abcd);
        fifo_step(0, 0, 1, '0);
        $display("PASS FIFO component depth=%0d", DEPTH);
        complete_o = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module tb_components;
    logic clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = !clk;
    end

    logic [2:0] fifo_complete;
    rp_fifo_check #(.DEPTH(1)) fifo_depth_1 (.clk_i(clk), .complete_o(fifo_complete[0]));
    rp_fifo_check #(.DEPTH(3)) fifo_depth_3 (.clk_i(clk), .complete_o(fifo_complete[1]));
    rp_fifo_check #(.DEPTH(255)) fifo_depth_255 (.clk_i(clk), .complete_o(fifo_complete[2]));

    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic abort_frame = 1'b0;
    logic cpol = 1'b0;
    logic cpha = 1'b0;
    logic lsb_first = 1'b0;
    logic [4:0] bits_minus_one = '0;
    logic [3:0] cs_index = '0;
    logic [15:0] divider = '0;
    logic [31:0] tx_data = '0;
    logic miso = 1'b0;
    logic busy, done, sclk, mosi;
    logic [15:0] cs_n;
    logic [31:0] rx_data;

    rp_spi_engine #(.NUM_CS(16)) engine (
        .clk_i(clk), .rst_ni(rst_n), .start_i(start), .abort_i(abort_frame),
        .cpol_i(cpol), .cpha_i(cpha), .lsb_first_i(lsb_first), .bits_minus_one_i(bits_minus_one),
        .cs_index_i(cs_index), .divider_i(divider), .tx_data_i(tx_data),
        .busy_o(busy), .done_o(done), .rx_data_o(rx_data), .sclk_o(sclk),
        .mosi_o(mosi), .cs_no(cs_n), .miso_i(miso)
    );

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic check_active(input logic [15:0] expected_select, input bit expected_clock);
        if (busy !== 1'b1 || done !== 1'b0 || cs_n !== expected_select || sclk !== expected_clock)
            $fatal(1, "SPI activity mismatch at t=%0t: busy=%b done=%b CS=%h SCLK=%b",
                   $time, busy, done, cs_n, sclk);
    endtask

    task automatic check_idle(input bit expected_done);
        if (busy !== 1'b0 || done !== expected_done || cs_n !== '1 || sclk !== cpol || mosi !== 1'b0)
            $fatal(1, "SPI idle mismatch at t=%0t: busy=%b done=%b CS=%h SCLK=%b MOSI=%b",
                   $time, busy, done, cs_n, sclk, mosi);
    endtask

    task automatic check_frame(
        input bit polarity, phase, low_first,
        input integer width, half_cycles,
        input logic [3:0] select,
        input logic [31:0] tx_word, rx_word
    );
        logic [15:0] expected_select;
        logic [31:0] mask;
        logic expected_mosi;
        integer bit_index;

        expected_select = ~(16'b1 << select);
        mask = 32'hffff_ffff >> (32-width);
        @(negedge clk);
        cpol = polarity;
        cpha = phase;
        lsb_first = low_first;
        bits_minus_one = 5'(width-1);
        cs_index = select;
        divider = 16'(half_cycles-1);
        tx_data = tx_word;
        start = 1'b1;
        #1;
        check_idle(0);
        tick();
        check_active(expected_select, polarity);
        if (mosi !== (phase ? 1'b0 : tx_word[low_first ? 0 : width-1]))
            $fatal(1, "SPI first MOSI bit did not follow CPHA");

        // Inputs may represent the next frame once this frame has started.
        start = 1'b0;
        cpha = !phase;
        lsb_first = !low_first;
        bits_minus_one = '0;
        cs_index = ~select;
        divider = '0;
        tx_data = ~tx_word;

        for (integer bit_number = 0; bit_number < width; bit_number++) begin
            bit_index = low_first ? bit_number : width-1-bit_number;
            expected_mosi = mosi;
            // The nonsampling edge sees the opposite value to detect wrong-edge sampling.
            miso = phase ? !rx_word[bit_index] : rx_word[bit_index];
            for (integer period = 1; period <= half_cycles; period++) begin
                tick();
                check_active(expected_select, (period == half_cycles) ? !polarity : polarity);
                if (period < half_cycles && mosi !== expected_mosi)
                    $fatal(1, "SPI MOSI changed before the leading edge");
            end
            if (mosi !== tx_word[bit_index])
                $fatal(1, "SPI MOSI mismatch at leading edge for bit %0d", bit_index);

            miso = phase ? rx_word[bit_index] : !rx_word[bit_index];
            for (integer period = 1; period <= half_cycles; period++) begin
                tick();
                check_active(expected_select, (period == half_cycles) ? polarity : !polarity);
                if ((phase || period < half_cycles) && mosi !== tx_word[bit_index])
                    $fatal(1, "SPI MOSI changed before the permitted launch edge");
            end
            if (!phase && bit_number < width-1 && mosi !== tx_word[low_first ? bit_index+1 : bit_index-1])
                $fatal(1, "SPI mode-%0d MOSI did not launch at trailing edge", polarity ? 2 : 0);
        end

        for (integer period = 1; period < half_cycles; period++) begin
            tick();
            check_active(expected_select, polarity);
        end
        tick();
        check_idle(1);
        if (rx_data !== (rx_word & mask))
            $fatal(1, "SPI RX was %h, expected %h", rx_data, rx_word & mask);
        tick();
        check_idle(0);
    endtask

    task automatic start_single_bit;
        @(negedge clk);
        cpol = 1'b1;
        cpha = 1'b1;
        lsb_first = 1'b1;
        cs_index = 4'hf;
        bits_minus_one = '0;
        divider = '0;
        start = 1'b1;
        tick();
        start = 1'b0;
        check_active(16'h7fff, 1);
    endtask

    task automatic check_abort_and_reset;
        start_single_bit();
        tick();
        check_active(16'h7fff, 0);
        abort_frame = 1'b1;
        tick();
        check_idle(0);
        abort_frame = 1'b0;
        repeat (3) begin
            tick();
            check_idle(0);
        end

        start_single_bit();
        tick();
        tick();
        check_active(16'h7fff, 1);
        abort_frame = 1'b1;
        tick();
        check_idle(0);
        abort_frame = 1'b0;

        start_single_bit();
        rst_n = 1'b0;
        cpol = 1'b0;
        tick();
        check_idle(0);
        if (rx_data !== '0)
            $fatal(1, "SPI RX data did not reset");
        rst_n = 1'b1;
        check_frame(0, 1, 0, 8, 2, 4'd0, 32'h0000_00a5, 32'h0000_005a);
    endtask

    initial begin
        tick();
        check_idle(0);
        rst_n = 1'b1;
        for (integer mode = 0; mode < 4; mode++) begin
            check_frame(mode[1], mode[0], 0, 32, 1, 4'd15, 32'h8a91_b3df, 32'hde60_5fa1);
            check_frame(mode[1], mode[0], 1, 13, 3, 4'd2, 32'h0000_1ad1, 32'h0000_13ae);
        end
        check_frame(1, 0, 0, 1, 65536, 4'd1, 32'h1, 32'h1);
        check_abort_and_reset();
        $display("PASS SPI component: 10 frames, max divider, abort during shift/hold, reset and recovery");
        wait (&fifo_complete);
        $display("PASS tb_components");
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "Component test timeout");
    end
endmodule
