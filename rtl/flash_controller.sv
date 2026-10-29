`timescale 1ns/1ps
module flash_controller #(
    parameter integer POWERUP_CYCLES = 500_000,
    parameter integer POLL_CYCLES = 5_000,
    parameter integer PROGRAM_TIMEOUT = 500_000,
    parameter integer ERASE_TIMEOUT = 30_000_000
) (
    input wire clk, reset_n, start,
    input wire [1:0] operation, // 0: read page, 1: program page, 2: erase sector
    input wire [23:0] address,
    output wire ready,
    output reg done, error,
    output wire [7:0] write_index,
    input wire [7:0] write_data,
    output reg read_valid,
    output reg [7:0] read_index, read_data,
    output reg spi_cs,
    output wire spi_clk, spi_mosi,
    input wire spi_miso
);
    localparam POWER=0, IDLE=1, STATUS_BEGIN=2, STATUS_CMD=3,
        STATUS_DATA=4, STATUS_END=5, STATUS_CHECK=6, POLL_WAIT=7,
        WREN_BEGIN=8, WREN_SEND=9, WREN_END=10, WREN_GAP=11,
        OP_BEGIN=12, OP_CMD=13, OP_A2=14, OP_A1=15, OP_A0=16,
        OP_DATA=17, OP_END=18, OP_GAP=19, FINISH=20,
        BYTE_START=21, BYTE_WAIT=22, STATUS_GAP=23;
    reg [4:0] state, continuation;
    reg [1:0] op, status_phase;
    reg [23:0] addr;
    reg [7:0] index, tx_byte, status_byte;
    reg byte_start;
    wire byte_done;
    wire [7:0] rx_byte;
    integer timer, gap_timer, timeout_limit;
    assign ready = state == IDLE;
    assign write_index = index;
    spi_byte shifter (
        .clk(clk), .reset_n(reset_n), .start(byte_start), .tx_data(tx_byte),
        .miso(spi_miso), .sck(spi_clk), .mosi(spi_mosi),
        .rx_data(rx_byte), .busy(), .done(byte_done)
    );
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= POWER; continuation <= IDLE; spi_cs <= 1;
            done <= 0; error <= 0; byte_start <= 0; read_valid <= 0;
            read_index <= 0; read_data <= 0; op <= 0; addr <= 0;
            index <= 0; tx_byte <= 0; status_byte <= 0; status_phase <= 0;
            timer <= 0; gap_timer <= POWERUP_CYCLES; timeout_limit <= PROGRAM_TIMEOUT;
        end else begin
            done <= 0; byte_start <= 0; read_valid <= 0;
            if (state != POWER && state != IDLE && state != FINISH)
                timer <= timer+1;
            case (state)
                POWER: if (gap_timer == 0) state <= IDLE;
                       else gap_timer <= gap_timer-1;
                IDLE: if (start) begin
                    op <= operation; addr <= address; error <= 0; timer <= 0;
                    status_phase <= 0;
                    timeout_limit <= operation == 2 ? ERASE_TIMEOUT : PROGRAM_TIMEOUT;
                    state <= STATUS_BEGIN;
                end
                STATUS_BEGIN: begin spi_cs <= 0; state <= STATUS_CMD; end
                STATUS_CMD: begin
                    tx_byte <= 8'h05; continuation <= STATUS_DATA; state <= BYTE_START;
                end
                STATUS_DATA: begin
                    tx_byte <= 8'hff; continuation <= STATUS_END; state <= BYTE_START;
                end
                STATUS_END: begin
                    status_byte <= rx_byte; spi_cs <= 1; gap_timer <= 4;
                    state <= STATUS_GAP;
                end
                STATUS_GAP: if (gap_timer == 0) state <= STATUS_CHECK;
                            else gap_timer <= gap_timer-1;
                STATUS_CHECK: begin
                    if (status_byte[0]) begin
                        gap_timer <= POLL_CYCLES; state <= POLL_WAIT;
                    end else if (status_phase == 0) begin
                        if (op == 0) state <= OP_BEGIN;
                        else state <= WREN_BEGIN;
                    end else if (status_phase == 1) begin
                        if (!status_byte[1]) begin error <= 1; state <= FINISH; end
                        else state <= OP_BEGIN;
                    end else begin
                        // WEL must clear after an accepted program/erase.
                        error <= status_byte[1]; state <= FINISH;
                    end
                end
                POLL_WAIT: if (gap_timer == 0) state <= STATUS_BEGIN;
                           else gap_timer <= gap_timer-1;
                WREN_BEGIN: begin spi_cs <= 0; state <= WREN_SEND; end
                WREN_SEND: begin
                    tx_byte <= 8'h06; continuation <= WREN_END; state <= BYTE_START;
                end
                WREN_END: begin
                    spi_cs <= 1; gap_timer <= 4; state <= WREN_GAP;
                end
                WREN_GAP: if (gap_timer == 0) begin
                    status_phase <= 1; state <= STATUS_BEGIN;
                end else gap_timer <= gap_timer-1;
                OP_BEGIN: begin spi_cs <= 0; index <= 0; state <= OP_CMD; end
                OP_CMD: begin
                    tx_byte <= op == 0 ? 8'h03 : op == 1 ? 8'h02 : 8'h20;
                    continuation <= OP_A2; state <= BYTE_START;
                end
                OP_A2: begin
                    tx_byte <= addr[23:16]; continuation <= OP_A1; state <= BYTE_START;
                end
                OP_A1: begin
                    tx_byte <= addr[15:8]; continuation <= OP_A0; state <= BYTE_START;
                end
                OP_A0: begin
                    tx_byte <= addr[7:0];
                    continuation <= op == 2 ? OP_END : OP_DATA; state <= BYTE_START;
                end
                OP_DATA: begin
                    tx_byte <= op == 1 ? write_data : 8'hff;
                    continuation <= OP_END; state <= BYTE_START;
                end
                OP_END: begin
                    if (op == 0) begin
                        read_valid <= 1; read_index <= index; read_data <= rx_byte;
                    end
                    if (op != 2 && index != 255) begin
                        index <= index+1'b1; state <= OP_DATA;
                    end else begin
                        spi_cs <= 1; gap_timer <= 4; state <= OP_GAP;
                        if (op != 0) begin
                            timer <= 0; status_phase <= 2;
                        end
                    end
                end
                OP_GAP: if (gap_timer == 0) begin
                    if (op == 0) state <= FINISH;
                    else begin gap_timer <= POLL_CYCLES; state <= POLL_WAIT; end
                end else gap_timer <= gap_timer-1;
                BYTE_START: begin byte_start <= 1; state <= BYTE_WAIT; end
                BYTE_WAIT: if (byte_done) state <= continuation;
                FINISH: begin spi_cs <= 1; done <= 1; state <= IDLE; end
                default: begin spi_cs <= 1; error <= 1; state <= FINISH; end
            endcase
            // Abort only between bytes: CS must never rise while SCK is high.
            if (state != POWER && state != IDLE && state != FINISH &&
                state != BYTE_START && state != BYTE_WAIT && timer >= timeout_limit) begin
                spi_cs <= 1; error <= 1; state <= FINISH;
            end
        end
    end
endmodule
