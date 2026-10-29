RTL := $(wildcard rtl/*.sv)
SIM := sim/w25q128_model.sv sim/tb_programmer.sv

.PHONY: test sim sim-fast sim-limits python-test synth clean
test: python-test sim sim-fast sim-limits synth

build:
	mkdir -p build

sim: build
	iverilog -g2012 -Wall -s tb_programmer -o build/tb $(RTL) $(SIM)
	vvp build/tb

sim-fast: build
	iverilog -g2012 -Wall -s tb_programmer -Ptb_programmer.BAUD=1000000 -Ptb_programmer.IMAGE_SIZE=4353 -o build/tb-fast $(RTL) $(SIM)
	vvp build/tb-fast

sim-limits: build
	iverilog -g2012 -Wall -s tb_flash_limits -o build/tb-limits $(RTL) sim/w25q128_model.sv sim/tb_flash_limits.sv
	vvp build/tb-limits

python-test:
	python3 -m unittest discover -s tests -v

synth: build
	yosys -Q -T -p 'read_verilog -sv $(RTL); hierarchy -check -top uart_flash_programmer; proc; opt; memory; opt; check -assert; stat' > build/synthesis.log

clean:
	rm -f build/tb build/tb-fast build/tb-limits build/programmer.vcd build/synthesis.log
