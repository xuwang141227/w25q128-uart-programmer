`timescale 1ns/1ps
module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 19200
) (
    input wire clk, reset_n, rx,
    output reg [7:0] data,
    output reg valid, frame_error
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_rx;
    reg [2:0] state;
    integer ticks;
    reg [2:0] bit_no;
    reg [7:0] shift;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) sync_rx <= 2'b11;
        else sync_rx <= {sync_rx[0], rx};
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= 0; ticks <= 0; bit_no <= 0;
            shift <= 0; data <= 0; valid <= 0; frame_error <= 0;
        end else begin
            valid <= 0; frame_error <= 0;
            case (state)
                0: if (!sync_rx[1]) begin ticks <= DIV/2-1; state <= 1; end
                1: if (ticks != 0) ticks <= ticks-1;
                   else if (!sync_rx[1]) begin
                       ticks <= DIV-1; bit_no <= 0; state <= 2;
                   end else state <= 0;
                2: if (ticks != 0) ticks <= ticks-1;
                   else begin
                       shift[bit_no] <= sync_rx[1]; ticks <= DIV-1;
                       if (bit_no == 7) state <= 3;
                       else bit_no <= bit_no+1'b1;
                   end
                3: if (ticks != 0) ticks <= ticks-1;
                   else begin
                       if (sync_rx[1]) begin data <= shift; valid <= 1; end
                       else frame_error <= 1;
                       // Wait for idle after a break; do not decode a stuck-low line.
                       state <= sync_rx[1] ? 0 : 4;
                   end
                4: if (sync_rx[1]) state <= 0;
                default: state <= 0;
            endcase
        end
    end
endmodule
