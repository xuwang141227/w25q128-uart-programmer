`timescale 1ns/1ps
// Mode 0, MSB first. Two 50 MHz clocks per half period: 12.5 Mbit/s.
module spi_byte (
    input wire clk, reset_n, start,
    input wire [7:0] tx_data,
    input wire miso,
    output reg sck, mosi,
    output reg [7:0] rx_data,
    output reg busy, done
);
    reg half_tick;
    reg [2:0] bit_no;
    reg [7:0] shift;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sck <= 0; mosi <= 0; rx_data <= 0; busy <= 0; done <= 0;
            half_tick <= 0; bit_no <= 0; shift <= 0;
        end else begin
            done <= 0;
            if (!busy) begin
                sck <= 0;
                if (start) begin
                    busy <= 1; shift <= tx_data; mosi <= tx_data[7];
                    bit_no <= 7; half_tick <= 0;
                end
            end else if (!half_tick) half_tick <= 1;
            else begin
                half_tick <= 0;
                if (!sck) begin sck <= 1; rx_data[bit_no] <= miso; end
                else begin
                    sck <= 0;
                    if (bit_no == 0) begin busy <= 0; done <= 1; end
                    else begin
                        bit_no <= bit_no-1'b1;
                        shift <= {shift[6:0], 1'b0}; mosi <= shift[6];
                    end
                end
            end
        end
    end
endmodule
