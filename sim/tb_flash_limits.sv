`timescale 1ns/1ps
module tb_flash_limits;
    reg clk=0, reset_n=0, start=0, stall=0;
    always #10 clk=~clk;
    reg [1:0] op=0;
    reg [23:0] address=0;
    wire ready, done, error, cs, sck, mosi, miso, read_valid;
    wire [7:0] write_index, read_index, read_data;
    integer read_count=0, polls;
    time started;
    flash_controller dut (
        .clk(clk), .reset_n(reset_n), .start(start), .operation(op),
        .address(address), .ready(ready), .done(done), .error(error),
        .write_index(write_index), .write_data(write_index ^ 8'ha5),
        .read_valid(read_valid), .read_index(read_index), .read_data(read_data),
        .spi_cs(cs), .spi_clk(sck), .spi_mosi(mosi), .spi_miso(miso)
    );
    w25q128_model #(.CAPACITY(8192), .PROGRAM_NS(3_000_000),
                    .ERASE_NS(400_000_000)) flash (
        .cs_n(cs), .sck(sck), .mosi(mosi), .miso(miso),
        .force_busy(1'b0), .reject_wren(1'b0), .stall_completion(stall)
    );
    always @(posedge clk) if (read_valid) begin
        if (read_index !== read_count[7:0] || read_data !== (read_index ^ 8'ha5))
            $fatal(1, "Limit test readback mismatch");
        read_count=read_count+1;
    end
    task launch(input [1:0] operation);
        begin
            wait(ready);
            @(negedge clk); op=operation; start=1; started=$time;
            @(negedge clk); start=0;
        end
    endtask
    task completion(input reg expected_error);
        begin
            wait(done);
            if (error !== expected_error || !cs || sck)
                $fatal(1, "Unexpected completion or unsafe SPI idle");
            @(negedge clk);
        end
    endtask
    initial begin
        #2_000_000_000; $fatal(1, "Limit test watchdog");
    end
    initial begin
        #100; reset_n=1;
        #9_000_000;
        if (ready || !cs) $fatal(1, "Power-up guard too short");
        launch(2); completion(0);
        if ($time-started < 400_000_000 || flash.erase_count != 1)
            $fatal(1, "Erase completed before datasheet maximum duration");
        $display("PASS 400 ms sector erase with 600 ms timeout");
        launch(1); completion(0);
        if ($time-started < 3_000_000 || flash.program_count != 1)
            $fatal(1, "Program completed before 3 ms");
        $display("PASS 3 ms page program with 10 ms timeout");
        launch(0); completion(0);
        if (read_count != 256) $fatal(1, "Read count");
        polls=flash.poll_count;
        #1_000_000;
        if (polls != flash.poll_count) $fatal(1, "Idle polling");
        stall=1;
        launch(1); completion(1);
        if ($time-started < 10_000_000 || !flash.busy)
            $fatal(1, "Programming timeout not exercised");
        polls=flash.poll_count;
        #1_000_000;
        if (polls != flash.poll_count) $fatal(1, "Polling continues after timeout");
        $display("PASS actual program BUSY timeout and polling stops");
        stall=0;
        // A subsequent status read refreshes the completed model operation.
        read_count=0;
        launch(0); completion(0);
        stall=1;
        launch(2); completion(1);
        if ($time-started < 600_000_000 || !flash.busy)
            $fatal(1, "Erase timeout not exercised");
        $display("PASS actual erase BUSY timeout at 600 ms");
        $display("ALL FLASH LIMIT TESTS PASSED");
        $finish;
    end
endmodule
