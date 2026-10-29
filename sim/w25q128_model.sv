`timescale 1ns/1ps
// Behavioral subset, not a replacement for Winbond's vendor model.
module w25q128_model #(
    parameter integer CAPACITY = 65536,
    parameter integer PROGRAM_NS = 400_000,
    parameter integer ERASE_NS = 2_000_000
) (
    input wire cs_n, sck, mosi,
    output reg miso,
    input wire force_busy, reject_wren, stall_completion
);
    reg [7:0] memory [0:CAPACITY-1];
    reg [7:0] buffer [0:255];
    reg [7:0] command, shift, incoming, output_byte;
    reg [23:0] address;
    integer bits_in, bytes_in, data_count, i, location;
    reg wel, busy;
    time busy_until, last_cs_rise, last_edge;
    integer program_count, erase_count, poll_count;
    task refresh;
        begin if (busy && !stall_completion && $time >= busy_until) busy = 0; end
    endtask
    initial begin
        miso = 1; wel = 0; busy = 0; busy_until = 0;
        last_cs_rise = 0; last_edge = 0;
        program_count = 0; erase_count = 0; poll_count = 0;
        for (i=0; i<CAPACITY; i=i+1) memory[i] = 8'h00;
    end
    always @(negedge cs_n) begin
        if ($time-last_cs_rise < 50) $fatal(1, "CS high time below 50 ns");
        if (sck !== 0) $fatal(1, "CS asserted with SCK high");
        refresh;
        bits_in = 0; bytes_in = 0; data_count = 0;
        command = 0; shift = 0; address = 0; miso = 1; last_edge = 0;
    end
    always @(posedge sck) if (!cs_n) begin
        if (last_edge != 0 && (($time-last_edge < 40) ||
            (bits_in != 0 && $time-last_edge != 40)))
            $fatal(1, "SPI half period must be 40 ns (idle byte gaps allowed)");
        last_edge = $time;
        incoming = {shift[6:0], mosi};
        shift = incoming;
        if (bits_in == 7) begin
            bits_in = 0;
            if (bytes_in == 0) begin
                command = incoming;
                refresh;
                if ((busy || force_busy) && command != 8'h05)
                    $fatal(1, "Non-status command during BUSY");
                if (command == 8'h05) poll_count = poll_count+1;
                if (command != 8'h05 && command != 8'h06 &&
                    command != 8'h02 && command != 8'h03 && command != 8'h20)
                    $fatal(1, "Unsupported SPI opcode %h", command);
            end else if ((command == 8'h02 || command == 8'h03 || command == 8'h20) &&
                         bytes_in <= 3) address = {address[15:0], incoming};
            else if (command == 8'h02) begin
                if (data_count == 256) $fatal(1, "Page program overflow");
                buffer[data_count] = incoming; data_count = data_count+1;
            end
            bytes_in = bytes_in+1;
        end else bits_in = bits_in+1;
    end
    always @(negedge sck) if (!cs_n) begin
        if ($time-last_edge != 40) $fatal(1, "SPI high time must be 40 ns");
        last_edge = $time;
        refresh;
        output_byte = 8'hff;
        if (command == 8'h05 && bytes_in >= 1)
            output_byte = {6'b0, wel, (busy || force_busy)};
        if (command == 8'h03 && bytes_in >= 4) begin
            location = address + bytes_in-4;
            if (location >= CAPACITY) $fatal(1, "Read exceeds model capacity");
            output_byte = memory[location];
        end
        miso = output_byte[7-bits_in];
    end
    always @(posedge cs_n) begin
        if ($time > 0) begin
            if (sck !== 0) $fatal(1, "CS released with SCK high");
            last_cs_rise = $time;
            if (bits_in != 0) $fatal(1, "Partial SPI byte");
            refresh;
            if (command == 8'h06 && !reject_wren && !busy && !force_busy) wel = 1;
            if (command == 8'h02 || command == 8'h20) begin
                if (!wel || busy || force_busy) $fatal(1, "Modify without WEL/ready");
                if (bytes_in < 4) $fatal(1, "Missing address");
                if (address >= CAPACITY) $fatal(1, "Modify exceeds model capacity");
                if (command == 8'h02) begin
                    if (data_count != 256) $fatal(1, "Expected a full page");
                    if (address[7:0] != 0) $fatal(1, "Unaligned page program");
                    for (i=0; i<data_count; i=i+1)
                        memory[address+i] = memory[address+i] & buffer[i];
                    busy_until = $time+PROGRAM_NS; program_count = program_count+1;
                end else begin
                    location = (address/4096)*4096;
                    for (i=0; i<4096; i=i+1) memory[location+i] = 8'hff;
                    busy_until = $time+ERASE_NS; erase_count = erase_count+1;
                end
                busy = 1; wel = 0;
            end
            miso = 1;
        end
    end
endmodule
