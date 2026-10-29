`timescale 1ns/1ps
module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 19200
) (
    input wire clk, reset_n, start,
    input wire [7:0] data,
    output reg tx, busy,
    output reg done
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    integer ticks;
    reg [3:0] bit_no;
    reg [9:0] frame;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tx <= 1; busy <= 0; done <= 0;
            ticks <= 0; bit_no <= 0; frame <= 10'h3ff;
        end else begin
            done <= 0;
            if (!busy) begin
                if (start) begin
                    frame <= {1'b1, data, 1'b0}; tx <= 0; busy <= 1;
                    bit_no <= 0; ticks <= DIV-1;
                end
            end else if (ticks != 0) ticks <= ticks-1;
            else if (bit_no == 9) begin
                busy <= 0; tx <= 1; done <= 1;
            end else begin
                bit_no <= bit_no+1'b1; tx <= frame[bit_no+1'b1]; ticks <= DIV-1;
            end
        end
    end
endmodule
