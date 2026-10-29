#!/usr/bin/env python3
"""Host utility for programming a W25Q128 over the UART boot protocol."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Callable


MAGIC = b"\x55\xE1"
ERROR_REPLY = b"\x55\xE1\xF4"
BAUD_RATE = 19200
PAGE_SIZE = 256
SECTOR_SIZE = 4096
MAX_IMAGE_SIZE = 16 * 1024 * 1024
ERASE_SECONDS_PER_SECTOR = 0.6


class FlashError(Exception):
    """Base class for flash protocol and transport failures."""


class FlashTimeout(FlashError):
    """A protocol transaction did not complete before its deadline."""


class ProtocolError(FlashError):
    """The device returned an error or an unexpected response."""


def _uint32(value: int, name: str) -> bytes:
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError(f"{name} must fit in an unsigned 32-bit integer")
    return value.to_bytes(4, "big")


def validate_image(image: bytes) -> None:
    if not image:
        raise ValueError("the binary image must not be empty")
    if len(image) > MAX_IMAGE_SIZE:
        raise ValueError(
            f"image is {len(image)} bytes; maximum supported size is "
            f"{MAX_IMAGE_SIZE} bytes"
        )


class FlashHost:
    """Drive the UART protocol using any object with ``read`` and ``write``."""

    def __init__(
        self,
        transport,
        *,
        command_timeout: float = 2.0,
        erase_margin: float = 2.0,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        log: Callable[[str], None] = print,
    ):
        self.transport = transport
        self.command_timeout = command_timeout
        self.erase_margin = erase_margin
        self.sleep = sleep
        self.clock = clock
        self.log = log

    def _write_all(self, data: bytes, deadline: float) -> None:
        offset = 0
        while offset < len(data):
            remaining = deadline - self.clock()
            if remaining <= 0:
                raise FlashTimeout("timed out writing to the serial port")
            if hasattr(self.transport, "write_timeout"):
                self.transport.write_timeout = remaining
            try:
                count = self.transport.write(data[offset:])
            except (OSError, TimeoutError) as exc:
                raise FlashError(f"serial write failed: {exc}") from exc
            if count is None or count <= 0:
                raise FlashTimeout("serial write made no progress")
            if count > len(data) - offset:
                raise ProtocolError("serial transport reported an invalid write length")
            offset += count

    def _read_exact(self, count: int, deadline: float) -> bytes:
        result = bytearray()
        while len(result) < count:
            remaining = deadline - self.clock()
            if remaining <= 0:
                exc = FlashTimeout(
                    f"timed out reading from the device ({len(result)}/{count} bytes)"
                )
                exc.partial = bytes(result)
                raise exc
            # pySerial's read timeout must not extend past this transaction's deadline.
            if hasattr(self.transport, "timeout"):
                self.transport.timeout = remaining
            try:
                chunk = self.transport.read(count - len(result))
            except (OSError, TimeoutError) as exc:
                raise FlashError(f"serial read failed: {exc}") from exc
            if chunk:
                if len(chunk) > count - len(result):
                    raise ProtocolError("serial transport returned more bytes than requested")
                result.extend(chunk)
        return bytes(result)

    def _ack(self, expected: int, deadline: float) -> None:
        reply = self._read_exact(3, deadline)
        self.log(f"Received: {reply.hex(' ').upper()}")
        if reply == ERROR_REPLY:
            raise ProtocolError("device reported protocol error 55 E1 F4")
        wanted = MAGIC + bytes((expected,))
        if reply != wanted:
            raise ProtocolError(
                f"unexpected device response {reply.hex(' ').upper()}; "
                f"expected {wanted.hex(' ').upper()}"
            )

    def _command(
        self,
        command: int,
        payload: bytes = b"",
        *,
        expected: int,
        timeout: float | None = None,
    ) -> None:
        deadline = self.clock() + (
            self.command_timeout if timeout is None else timeout
        )
        frame = MAGIC + bytes((command,)) + payload
        details = f"{MAGIC.hex(' ').upper()} {command:02X}"
        if command == 0xE3:
            details += f" ({len(payload)} data bytes)"
        elif payload:
            details += f" {payload.hex(' ').upper()}"
        self.log(f"Sending: {details}")
        self._write_all(frame, deadline)
        self._ack(expected, deadline)

    def begin(self, image_size: int) -> None:
        if not 1 <= image_size <= MAX_IMAGE_SIZE:
            raise ValueError(
                f"image size must be between 1 and {MAX_IMAGE_SIZE} bytes"
            )
        self._command(0xE1, _uint32(image_size, "image size"), expected=0xF1)
        self.log(f"Device accepted image size: {image_size} bytes")

    def erase(self, image_size: int) -> int:
        if not 1 <= image_size <= MAX_IMAGE_SIZE:
            raise ValueError(
                f"image size must be between 1 and {MAX_IMAGE_SIZE} bytes"
            )
        sectors = (image_size + SECTOR_SIZE - 1) // SECTOR_SIZE
        erase_size = sectors * SECTOR_SIZE
        timeout = sectors * ERASE_SECONDS_PER_SECTOR + self.erase_margin
        self._command(0xE2, expected=0xF2, timeout=timeout)
        self.log(f"Erase acknowledged for {sectors} sector(s) ({erase_size} bytes)")
        return erase_size

    def set_read_mode(self) -> None:
        self._command(0xF5, expected=0xF6)
        self.log("Device confirmed read mode")

    def set_write_mode(self) -> None:
        self._command(0xFA, expected=0xFB)
        self.log("Device confirmed write mode")

    def read_page(self, address: int) -> bytes:
        if not 0 <= address <= MAX_IMAGE_SIZE - PAGE_SIZE:
            raise ValueError(
                f"page address must be between 0 and {MAX_IMAGE_SIZE - PAGE_SIZE}"
            )
        deadline = self.clock() + self.command_timeout
        frame = MAGIC + b"\xE6" + _uint32(address, "address")
        self.log(
            f"Sending: {MAGIC.hex(' ').upper()} E6 "
            f"address={address:08X}"
        )
        self._write_all(frame, deadline)
        try:
            page = self._read_exact(PAGE_SIZE, deadline)
            self.log(f"Received raw page: {len(page)} bytes")
            return page
        except FlashTimeout as exc:
            partial = getattr(exc, "partial", b"")
            if partial == ERROR_REPLY:
                raise ProtocolError("device reported protocol error 55 E1 F4") from exc
            raise

    def erase_sector(self, address: int) -> None:
        """Send an address-qualified E7 erase-sector command."""
        if not 0 <= address < MAX_IMAGE_SIZE:
            raise ValueError(
                f"sector address must be between 0 and {MAX_IMAGE_SIZE - 1}"
            )
        self._command(0xE7, _uint32(address, "address"), expected=0xF7)

    def reboot(self) -> None:
        deadline = self.clock() + self.command_timeout
        frame = MAGIC + b"\xE4"
        self.log(f"Sending: {frame.hex(' ').upper()}")
        self._write_all(frame, deadline)
        if hasattr(self.transport, "flush"):
            try:
                self.transport.flush()
            except OSError as exc:
                raise FlashError(f"serial flush failed: {exc}") from exc

    def program(self, image: bytes) -> None:
        validate_image(image)
        self.erase(len(image))
        page_count = (len(image) + PAGE_SIZE - 1) // PAGE_SIZE
        for page_index in range(page_count):
            offset = page_index * PAGE_SIZE
            chunk = image[offset : offset + PAGE_SIZE]
            page = chunk.ljust(PAGE_SIZE, b"\xFF")
            expected_ack = 0xF3 if page_index == page_count - 1 else 0xF2
            self._command(0xE3, page, expected=expected_ack)

            self.sleep(0.01)
            self.set_read_mode()
            readback = self.read_page(offset)
            if readback != page:
                mismatch = next(
                    i for i, (actual, wanted) in enumerate(zip(readback, page))
                    if actual != wanted
                )
                raise ProtocolError(
                    f"verification failed at address 0x{offset + mismatch:08X}: "
                    f"read {readback[mismatch]:02X}, expected {page[mismatch]:02X}"
                )
            self.log(f"Verified page {page_index + 1}/{page_count}")
            self.set_write_mode()
        self.log(f"Programming complete: verified {page_count} page(s)")


def _load_image(path: Path) -> bytes:
    with path.open("rb") as stream:
        image = stream.read(MAX_IMAGE_SIZE + 1)
    validate_image(image)
    return image


def _open_serial(port: str):
    try:
        import serial
    except ImportError as exc:
        raise FlashError(
            "pyserial is required for the CLI; install dependencies with "
            "`python -m pip install -r requirements.txt`"
        ) from exc

    return serial.Serial(
        port=port,
        baudrate=BAUD_RATE,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.1,
        write_timeout=2.0,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Program a W25Q128 flash device over 19200-baud 8N1 UART."
    )
    parser.add_argument("--port", required=True, help="serial port, e.g. /dev/ttyUSB0")
    parser.add_argument("--bin", required=True, type=Path, help="binary image to flash")
    parser.add_argument(
        "--reboot", action="store_true", help="reboot the target after successful verification"
    )
    args = parser.parse_args(argv)

    try:
        image = _load_image(args.bin)
        print(f"Loaded {len(image)} bytes from {args.bin}")
        with _open_serial(args.port) as serial_port:
            host = FlashHost(serial_port)
            host.begin(len(image))
            answer = input("Ready to erase and program the flash. Type yes to continue: ")
            if answer.strip().lower() != "yes":
                print("Cancelled; flash was not erased.")
                return 0
            host.program(image)
            if args.reboot:
                host.reboot()
        print("Flash programming and verification complete.")
        return 0
    except (FlashError, OSError, ValueError, EOFError) as exc:
        print(f"flash_host: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("flash_host: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
