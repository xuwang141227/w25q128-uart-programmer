`timescale 1ns/1ps
module uart_flash_programmer #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 19200,
    parameter integer POWERUP_CYCLES = 500_000,
    parameter integer POLL_CYCLES = 5_000,
    parameter integer PROGRAM_TIMEOUT = 500_000,
    parameter integer ERASE_TIMEOUT = 30_000_000,
    parameter integer RX_TIMEOUT = 5_000_000
) (
    input wire clk, reset_n,
    input wire uart_rx,
    output wire uart_tx,
    output wire spi_cs, spi_clk, spi_mosi,
    input wire spi_miso,
    output reg reboot_n
);
    localparam HEADER=0, PREFIX=1, COMMAND=2, ARGUMENT=3, PAYLOAD=4,
        DISPATCH=5, FLASH_START=6, FLASH_WAIT=7, SEND=8, SENT=9;
    reg [3:0] state;
    wire [7:0] rx_data;
    wire rx_valid, rx_error, tx_done;
    reg tx_start;
    reg [7:0] tx_data;
    reg [7:0] page [0:255];
    reg [7:0] command, response;
    reg [31:0] argument, total_length, written, erase_cursor;
    reg [1:0] arg_index, flash_op;
    reg [7:0] page_index;
    reg [8:0] tx_index;
    reg read_mode, image_erased, raw_response, flash_start;
    reg [23:0] flash_address;
    wire flash_ready, flash_done, flash_error, read_valid;
    wire [7:0] write_index, read_index, read_data;
    integer rx_timer;
    wire receiving = state == PREFIX || state == COMMAND ||
                     state == ARGUMENT || state == PAYLOAD;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) receiver (
        .clk(clk), .reset_n(reset_n), .rx(uart_rx), .data(rx_data),
        .valid(rx_valid), .frame_error(rx_error)
    );
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) transmitter (
        .clk(clk), .reset_n(reset_n), .start(tx_start), .data(tx_data),
        .tx(uart_tx), .busy(), .done(tx_done)
    );
    flash_controller #(
        .POWERUP_CYCLES(POWERUP_CYCLES), .POLL_CYCLES(POLL_CYCLES),
        .PROGRAM_TIMEOUT(PROGRAM_TIMEOUT), .ERASE_TIMEOUT(ERASE_TIMEOUT)
    ) flash (
        .clk(clk), .reset_n(reset_n), .start(flash_start), .operation(flash_op),
        .address(flash_address), .ready(flash_ready), .done(flash_done),
        .error(flash_error), .write_index(write_index), .write_data(page[write_index]),
        .read_valid(read_valid), .read_index(read_index), .read_data(read_data),
        .spi_cs(spi_cs), .spi_clk(spi_clk), .spi_mosi(spi_mosi), .spi_miso(spi_miso)
    );
    task ack(input [7:0] code);
        begin
            response <= code; raw_response <= 0; tx_index <= 0; state <= SEND;
        end
    endtask
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= HEADER; reboot_n <= 1; tx_start <= 0; tx_data <= 0;
            command <= 0; response <= 0; argument <= 0; arg_index <= 0;
            total_length <= 0; written <= 0; erase_cursor <= 0; page_index <= 0;
            read_mode <= 0; image_erased <= 0; raw_response <= 0; tx_index <= 0;
            flash_start <= 0; flash_op <= 0; flash_address <= 0; rx_timer <= 0;
        end else begin
            tx_start <= 0; flash_start <= 0;
            if (read_valid) page[read_index] <= read_data;
            if (receiving && !rx_valid) rx_timer <= rx_timer+1;
            else rx_timer <= 0;
            case (state)
                HEADER: if (rx_valid && rx_data == 8'h55) state <= PREFIX;
                PREFIX: if (rx_valid) begin
                    if (rx_data == 8'he1) state <= COMMAND;
                    else if (rx_data != 8'h55) state <= HEADER;
                end
                COMMAND: if (rx_valid) begin
                    command <= rx_data;
                    case (rx_data)
                        8'he1, 8'he6, 8'he7: begin
                            argument <= 0; arg_index <= 0; state <= ARGUMENT;
                        end
                        8'he3: begin page_index <= 0; state <= PAYLOAD; end
                        8'he2, 8'he4, 8'hf5, 8'hfa: state <= DISPATCH;
                        default: ack(8'hf4);
                    endcase
                end
                ARGUMENT: if (rx_valid) begin
                    argument <= {argument[23:0], rx_data};
                    if (arg_index == 3) state <= DISPATCH;
                    else arg_index <= arg_index+1'b1;
                end
                PAYLOAD: if (rx_valid) begin
                    page[page_index] <= rx_data;
                    if (page_index == 255) state <= DISPATCH;
                    else page_index <= page_index+1'b1;
                end
                DISPATCH: case (command)
                    8'he1: begin
                        if (argument == 0 || argument > 32'h01000000) ack(8'hf4);
                        else begin
                            total_length <= argument; written <= 0; image_erased <= 0;
                            ack(8'hf1);
                        end
                    end
                    8'he2: begin
                        if (read_mode || total_length == 0) ack(8'hf4);
                        else begin
                            image_erased <= 0; written <= 0; erase_cursor <= 0;
                            flash_address <= 0; flash_op <= 2; state <= FLASH_START;
                        end
                    end
                    8'he3: begin
                        if (read_mode || !image_erased || written >= total_length)
                            ack(8'hf4);
                        else begin
                            flash_address <= written[23:0]; flash_op <= 1;
                            state <= FLASH_START;
                        end
                    end
                    8'he4: begin reboot_n <= 0; state <= HEADER; end
                    8'hf5: begin read_mode <= 1; ack(8'hf6); end
                    8'hfa: begin read_mode <= 0; ack(8'hfb); end
                    8'he6: begin
                        if (!read_mode || argument > 32'h00ffff00) ack(8'hf4);
                        else begin
                            flash_address <= argument[23:0]; flash_op <= 0;
                            state <= FLASH_START;
                        end
                    end
                    8'he7: begin
                        if (read_mode || argument >= 32'h01000000) ack(8'hf4);
                        else begin
                            // Independent sector erase invalidates the image write session.
                            image_erased <= 0;
                            flash_address <= {argument[23:12], 12'b0};
                            flash_op <= 2; state <= FLASH_START;
                        end
                    end
                    default: ack(8'hf4);
                endcase
                FLASH_START: if (flash_ready) begin
                    flash_start <= 1; state <= FLASH_WAIT;
                end
                FLASH_WAIT: if (flash_done) begin
                    if (flash_error) begin
                        image_erased <= 0; ack(8'hf4);
                    end else case (command)
                        8'he2: if (erase_cursor+4096 >= total_length) begin
                            image_erased <= 1; ack(8'hf2);
                        end else begin
                            erase_cursor <= erase_cursor+4096;
                            flash_address <= erase_cursor[23:0]+24'd4096;
                            state <= FLASH_START;
                        end
                        8'he3: begin
                            written <= written+256;
                            if (written+256 >= total_length) ack(8'hf3);
                            else ack(8'hf2);
                        end
                        8'he6: begin raw_response <= 1; tx_index <= 0; state <= SEND; end
                        8'he7: ack(8'hf7);
                        default: ack(8'hf4);
                    endcase
                end
                SEND: begin
                    tx_data <= raw_response ? page[tx_index[7:0]] :
                               tx_index == 0 ? 8'h55 : tx_index == 1 ? 8'he1 : response;
                    tx_start <= 1; state <= SENT;
                end
                SENT: if (tx_done) begin
                    if (tx_index == (raw_response ? 9'd255 : 9'd2)) state <= HEADER;
                    else begin tx_index <= tx_index+1'b1; state <= SEND; end
                end
                default: state <= HEADER;
            endcase
            if (receiving && (rx_error || (!rx_valid && rx_timer >= RX_TIMEOUT))) begin
                // A truncated payload must not leave the old image session writable.
                if (state == PAYLOAD) image_erased <= 0;
                ack(8'hf4); rx_timer <= 0;
            end
        end
    end
endmodule
