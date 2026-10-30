# UART -> W25Q128JV FPGA 烧写器

50 MHz FPGA 主时钟，UART **19200 / 8N1**，标准单线 SPI Mode 0，
SPI 位时钟 **12.5 MHz**。提供可综合 SystemVerilog RTL、Python 串口工具、
模拟上位机流程的自检 TB 和独立 Flash 行为模型。

顶层为 `rtl/uart_flash_programmer.sv`。原始接口中缺少串口引脚，
因此增加 `uart_rx`、`uart_tx`；`spi_cs` 为**低有效片选**。

```verilog
uart_flash_programmer programmer (
    .clk(clk_50m), .reset_n(reset_n),
    .uart_rx(host_tx), .uart_tx(host_rx),
    .spi_cs(flash_cs_n), .spi_clk(flash_clk),
    .spi_mosi(flash_di), .spi_miso(flash_do),
    .reboot_n(reboot_n)
);
```

## 协议约定

所有数值均为十六进制；32 位长度/地址为**大端**，长度单位为**字节**，
不是包的数量。Flash 容量为 16 MiB，地址为 24 位。
UART 按字节低位先发；SPI 按字节高位先发。
上位机必须等待本条命令完成，才能发送下一条，不支持流水或并发命令。

| 主机发送 | FPGA 返回 | 行为 |
|---|---|---|
| `55 E1 E1 + length[31:0]` | `55 E1 F1` | 保存长度，重新开始镜像会话；合法范围 `1..0x01000000` |
| `55 E1 E2` | `55 E1 F2` | 从地址 0 擦除 `ceil(length/4096)` 个 sector，全部完成后返回 |
| `55 E1 E3 + 256 bytes` | `55 E1 F2` 或 `55 E1 F3` | 从地址 0 开始逐页写入；最后一页完成返回 F3 |
| `55 E1 E4` | 无 | 将 `reboot_n` 拉低，并保持到 `reset_n` 复位 |
| `55 E1 E6 + address[31:0]` | **原始 256 字节数据** | 从指定地址连续读；地址可不按页对齐，但必须 `<=0x00FFFF00` |
| `55 E1 E7 + address[31:0]` | `55 E1 F7` | 擦除该地址所在的 4 KiB sector，地址必须 `<0x01000000` |

失败统一返回 `55 E1 F4`：包括非法命令/长度/地址、
未擦除就写、写完后多发页、UART 接收超时/帧错误、WEL 未置位、
Flash BUSY 超时等。未知噪声不构成 `55 E1` 命令头时直接重新寻找头。

**无需切换读写模式**，可直接发送 E2/E3/E6/E7；旧 F5/FA 命令已移除，
发送时返回 F4。Python 与 FPGA RTL 必须配套更新。
E1 不自动擦除，必须完成 E2 后才能 E3。逐页读回不会
重置烧写地址。独立 E7、Flash 错误或截断的 E3 会使镜像烧写会话失效；
之后需要重新 E2（更换镜像时先重新 E1）。

末包仍须发送完整 256 字节，Python 工具用 `FF` 补齐；
RTL 每次编程 256 字节，按有效长度判断最后一页。
例如长度 `0x00000201` 为 513 字节：擦 1 个 sector，写 3 页，
第 3 页仅首字节有效，其余 255 字节为 `FF`。
sector 与 page 都从零地址开始，页写不会跨页回卷。

**读应答的歧义：**原协议未定义成功读应答头，因此 E6 成功时只返回
256 字节，失败时只返回 3 字节 F4。合法数据可以以 `55 E1 F4` 开头，
Python 不会误判，而是在读超时后，仅对“总共收到这 3 字节”判为设备错误。
协议没有 CRC、事务序号或转义，不应自动重发擦写命令；
链路错误后停止并重新启动完整烧写流程。

## Flash 手册与等待策略

实际读取的原厂文档：**Winbond W25Q128JV，Revision C，2016-11-16**，
非 W25Q128FV，也非只根据典型时间设置延时。
手册来自公开镜像中的原厂 PDF：
[W25Q128JV PDF](https://github.com/firefly/thirdparty-datasheets/blob/main/storage/w25q128jv.pdf)。
仅链接原文，不在仓库中复制手册。
具体章节、页码、硬件前提见 [docs/design.md](docs/design.md)。

| 参数 | 手册值 | 本实现默认策略（50 MHz） |
|---|---|---|
| 页编程 `tPP` | 典型 0.7 ms，最大 **3 ms** | BUSY 轮询，单次超时 **10 ms** |
| 4 KiB 擦除 `tSE` | 典型 45 ms，最大 **400 ms** | 每个 sector 独立轮询，单次超时 **600 ms** |
| 上电写等待 `tPUW` | 最小 **5 ms** | 复位释放后禁止访问 Flash **10 ms** |
| 上电读等待 `tVSL` | 最小 **20 us** | 同样由上述 10 ms 等待覆盖 |
| 擦写命令间 `/CS` 高电平 `tSHSL2` | 最小 **50 ns** | 状态机显式保留至少 4 个主时钟的间隔 |
| `03h` 普通读时钟 | 最大 **50 MHz** | **12.5 MHz**，每半周期 40 ns |

每次修改 Flash 前：读 `05h` 确认 BUSY=0 -> `06h` 写使能 ->
再次 `05h` 确认 WEL=1 -> `02h` 编程或 `20h` 擦除 ->
间隔约 **100 us** 轮询 `05h`。
BUSY 清零且 WEL 已清零后停止轮询，才向主机回复成功。
超时也停止轮询，SPI 安全回到空闲，返回 F4；不声称未完成的操作成功。
E6 先检查 BUSY，再使用 `03h + 24-bit address` 读取整页，
完整缓存成功后才从串口发送，不会先发送半页再插入错误码。

## Python 使用

Python 3.10+，建议使用虚拟环境：

```sh
python -m pip install -r requirements.txt
python tools/flash_host.py --port COM3 --bin firmware.bin
# Linux:
python tools/flash_host.py --port /dev/ttyUSB0 --bin firmware.bin
# 全部校验通过后才触发 reboot_n:
python tools/flash_host.py --port COM3 --bin firmware.bin --reboot
```

脚本流程：

1. 读取 bin 并验证大小，打印并发送 E1；收到 F1 后打印确认和字节长度。
2. 提示是否擦除烧写，**输入 `yes`** 才发送 E2；收到 F2 后开始逐页发送。
3. E3 收到 F2/F3 完成应答后等待 **20 ms**，直接发送 E6；
   读取刚写入的 256 字节，连同末页 `FF` 填充一起校验并打印包计数。
4. 校验成功后直接处理下一页，不发送模式切换命令；最后一页也必须读回成功，
   才打印整个镜像发送与校验完成。

脚本为每条命令打印 TX/ACK，但不会把全部 bin 内容刷到终端。
串口短读/短写会继续处理，超时、错误应答和校验失败会明确报错并退出，
不会自动重试。校验失败后不再继续发送任何命令。
整片范围擦除的等待上限按 sector 数量放大，不能用固定 2 秒等待所有擦除。
`--reboot` 是可选项，默认不会重启。

## 仿真与综合检查

Ubuntu/Debian 安装依赖：

```sh
sudo apt-get install iverilog yosys
make test
```

| 命令 | 覆盖内容 |
|---|---|
| `make sim` | 真实 50 MHz / 19200 baud / 12.5 MHz SPI，513 字节三页镜像，含非整页末包 |
| `make sim-fast` | UART 加速为 1 Mbaud，SPI/主时钟不变，4353 字节跨 sector 的 18 页镜像 |
| `make sim-limits` | 真实时钟下 3 ms 编程、400 ms 擦除以及编程/擦除实际 BUSY 卡死的 10/600 ms 超时 |
| `make python-test` | 不依赖串口硬件的 Python 主机协议、短读写、异常、校验、日志单元测试 |
| `make synth` | Yosys 层级、可综合性和结构一致性检查，日志在 `build/synthesis.log` |

串口 TB 从引脚逐位发送命令，不强制内部寄存器，也不绕过 UART。
Flash 模型解码真实 SPI 引脚，检查模式、40 ns 半周期、CS 高电平、
WREN/WEL、页对齐、擦除范围和 NOR 的 `1 -> 0` 编程行为；
包括延迟 BUSY、拒绝写使能、BUSY 卡死注入。
主流程按“写一页 -> 收到完成应答 -> 等待 20 ms -> 直接读回校验”执行。
回读数据特意包含 `55 E1 F4`，防止把数据误识别为命令/错误码。

需要波形时：

```sh
make build
iverilog -g2012 -s tb_programmer -o build/tb rtl/*.sv sim/w25q128_model.sv sim/tb_programmer.sv
vvp build/tb +vcd
# 输出 build/programmer.vcd，真实波特率的波形文件可能较大。
```

模型是本项目自写的标准 SPI 指令子集，**不是 Winbond 全功能认证模型**：
不覆盖保护位、掉电、模拟电气、Quad/QPI、挂起恢复或全部故障状态。
未提供 FPGA 器件/开发板型号，因此没有虚构管脚约束或可下载 bitstream；
Yosys 检查也不等于目标器件布局布线后的时序收敛或真实板卡验证。

## 文件

```text
rtl/uart_flash_programmer.sv   顶层协议、页缓存、地址和响应管理
rtl/flash_controller.sv       Flash 指令、WEL 检查、BUSY 轮询与超时
rtl/spi_byte.sv               SPI Mode 0 字节收发器
rtl/uart_rx.sv                UART 双级同步、起始/数据/停止位检查
rtl/uart_tx.sv                UART 发送器
sim/tb_programmer.sv          模拟 Python 行为的引脚级自检 TB
sim/tb_flash_limits.sv        最坏操作时长与超时测试
sim/w25q128_model.sv          Flash 行为模型
tools/flash_host.py           Python 上位机
tests/test_flash_host.py      主机单元测试
docs/design.md               设计、手册章节和上板说明
docs/verification.md         实际执行结果记录
```
