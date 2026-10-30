import unittest

from tools.flash_host import (
    ERROR_REPLY,
    FlashError,
    FlashHost,
    FlashTimeout,
    MAX_IMAGE_SIZE,
    PAGE_SIZE,
    ProtocolError,
    validate_image,
)


class FakeFpga:
    """Small streaming protocol peer that can fragment transport I/O."""

    def __init__(
        self,
        *,
        max_write=5,
        max_read=7,
        wrong_ack=None,
        silent_command=None,
        error_command=None,
        corrupt_readback=False,
        write_error=None,
        read_error=None,
    ):
        self.max_write = max_write
        self.max_read = max_read
        self.wrong_ack = wrong_ack
        self.silent_command = silent_command
        self.error_command = error_command
        self.corrupt_readback = corrupt_readback
        self.write_error = write_error
        self.read_error = read_error
        self.input = bytearray()
        self.output = bytearray()
        self.commands = []
        self.frames = []
        self.pages = []
        self.flash = bytearray(b"\xFF" * MAX_IMAGE_SIZE)
        self.image_size = 0
        self.timeout = 0.1
        self.flushed = False

    def flush(self):
        self.flushed = True

    def write(self, data):
        if self.write_error is not None:
            raise self.write_error
        data = bytes(data[: self.max_write])
        self.input.extend(data)
        self._process_commands()
        return len(data)

    def read(self, size):
        if self.read_error is not None:
            raise self.read_error
        amount = min(size, self.max_read, len(self.output))
        result = bytes(self.output[:amount])
        del self.output[:amount]
        return result

    def _process_commands(self):
        while len(self.input) >= 3:
            if self.input[:2] != b"\x55\xE1":
                raise AssertionError(f"bad command prefix: {self.input[:3]!r}")
            command = self.input[2]
            payload_length = {
                0xE1: 4,
                0xE2: 0,
                0xE3: PAGE_SIZE,
                0xE4: 0,
                0xE6: 4,
                0xE7: 4,
            }.get(command)
            if payload_length is None:
                raise AssertionError(f"unexpected command 0x{command:02X}")
            total = 3 + payload_length
            if len(self.input) < total:
                return
            payload = bytes(self.input[3:total])
            self.frames.append(bytes(self.input[:total]))
            del self.input[:total]
            self.commands.append((command, payload))
            self._execute(command, payload)

    def _reply(self, command, byte):
        if command == self.silent_command:
            return
        if command == self.error_command:
            self.output.extend(ERROR_REPLY)
        else:
            if isinstance(self.wrong_ack, tuple) and command == self.wrong_ack[0]:
                byte = self.wrong_ack[1]
            self.output.extend(b"\x55\xE1" + bytes((byte,)))

    def _execute(self, command, payload):
        if command == 0xE1:
            self.image_size = int.from_bytes(payload, "big")
            self._reply(command, 0xF1)
        elif command == 0xE2:
            erase_size = ((self.image_size + 4095) // 4096) * 4096
            self.flash[:erase_size] = b"\xFF" * erase_size
            self._reply(command, 0xF2)
        elif command == 0xE3:
            offset = len(self.pages) * PAGE_SIZE
            self.flash[offset : offset + PAGE_SIZE] = payload
            self.pages.append(payload)
            expected = 0xF3 if offset + PAGE_SIZE >= self.image_size else 0xF2
            self._reply(command, expected)
        elif command == 0xE6:
            if command == self.error_command:
                self.output.extend(ERROR_REPLY)
            else:
                address = int.from_bytes(payload, "big")
                page = bytes(self.flash[address : address + PAGE_SIZE])
                if self.corrupt_readback and address == 0:
                    page = bytes((page[0] ^ 1,)) + page[1:]
                self.output.extend(page)
        elif command == 0xE7:
            self._reply(command, 0xF7)


class FlashHostTests(unittest.TestCase):
    def setUp(self):
        self.fpga = FakeFpga()
        self.logs = []
        self.waits = []
        self.host = FlashHost(
            self.fpga,
            command_timeout=0.03,
            erase_margin=0.01,
            sleep=self.record_wait,
            log=self.logs.append,
        )

    def record_wait(self, seconds):
        self.waits.append(seconds)
        self.assertEqual(self.fpga.commands[-1][0], 0xE3)
        self.assertEqual(self.fpga.output, bytearray())

    def test_programs_513_bytes_with_padding_and_verifies_every_page(self):
        image = bytes((i % 251 for i in range(513)))
        self.host.begin(len(image))
        self.host.program(image)

        self.assertEqual(self.fpga.pages, [
            image[0:256],
            image[256:512],
            image[512:].ljust(256, b"\xFF"),
        ])
        self.assertEqual(
            [cmd for cmd, _ in self.fpga.commands].count(0xE6), 3
        )
        self.assertEqual(self.waits, [0.02] * 3)
        self.assertEqual(
            [cmd for cmd, _ in self.fpga.commands],
            [0xE1, 0xE2, 0xE3, 0xE6, 0xE3, 0xE6, 0xE3, 0xE6],
        )
        self.assertEqual(
            [payload for cmd, payload in self.fpga.commands if cmd == 0xE6],
            [address.to_bytes(4, "big") for address in (0, 256, 512)],
        )
        self.assertEqual(self.fpga.frames[1], b"\x55\xE1\xE2")
        self.assertIn(b"\x55\xE1\xE3" + image[512:].ljust(256, b"\xFF"),
                      self.fpga.frames)
        self.assertIn("Received: 55 E1 F3", self.logs)
        self.assertIn("Sending: 55 E1 E2", self.logs)
        self.assertIn("Received: 55 E1 F2", self.logs)
        self.assertIn("Verified page 3/3", self.logs)
        self.assertEqual(self.logs[-1], "Programming complete: verified 3 page(s)")

    def test_partial_reads_and_writes_are_completed(self):
        image = b"partial io test"
        self.host.begin(len(image))
        self.host.program(image)
        self.assertEqual(self.fpga.flash[: len(image)], image)
        self.assertEqual(self.fpga.input, bytearray())

    def test_wrong_ack_is_rejected(self):
        self.fpga.wrong_ack = (0xE1, 0xAA)
        with self.assertRaisesRegex(ProtocolError, "expected 55 E1 F1"):
            self.host.begin(1)

    def test_error_reply_is_rejected(self):
        self.fpga.error_command = 0xE1
        with self.assertRaisesRegex(ProtocolError, "55 E1 F4"):
            self.host.begin(1)

    def test_failed_page_write_does_not_wait_or_read(self):
        self.host.begin(1)
        self.fpga.error_command = 0xE3
        with self.assertRaisesRegex(ProtocolError, "55 E1 F4"):
            self.host.program(b"x")
        self.assertEqual(self.waits, [])
        self.assertEqual(
            [cmd for cmd, _ in self.fpga.commands], [0xE1, 0xE2, 0xE3]
        )

    def test_missing_ack_times_out(self):
        self.fpga.silent_command = 0xE1
        with self.assertRaises(FlashTimeout):
            self.host.begin(1)

    def test_transport_exceptions_are_reported(self):
        self.fpga.write_error = OSError("disconnected")
        with self.assertRaisesRegex(FlashError, "serial write failed"):
            self.host.begin(1)

        self.fpga.write_error = None
        self.fpga.read_error = OSError("disconnected")
        with self.assertRaisesRegex(FlashError, "serial read failed"):
            self.host.begin(1)

    def test_readback_mismatch_stops_without_more_commands(self):
        self.fpga.corrupt_readback = True
        self.host.begin(1)
        with self.assertRaisesRegex(ProtocolError, "verification failed"):
            self.host.program(b"x")
        self.assertEqual(
            [cmd for cmd, _ in self.fpga.commands],
            [0xE1, 0xE2, 0xE3, 0xE6],
        )

    def test_raw_page_beginning_with_error_prefix_is_valid_data(self):
        self.fpga.flash[:PAGE_SIZE] = ERROR_REPLY + b"\x00" * (PAGE_SIZE - 3)
        self.assertEqual(self.host.read_page(0)[:3], ERROR_REPLY)

    def test_short_raw_error_reply_is_reported_as_protocol_error(self):
        self.fpga.error_command = 0xE6
        with self.assertRaisesRegex(ProtocolError, "55 E1 F4"):
            self.host.read_page(0)

    def test_e7_address_command(self):
        self.host.erase_sector(0x00FFF123)
        self.assertEqual(self.fpga.commands[-1], (0xE7, b"\x00\xFF\xF1\x23"))

    def test_reboot_sends_no_response_command_and_drains_output(self):
        self.host.reboot()
        self.assertEqual(self.fpga.frames, [b"\x55\xE1\xE4"])
        self.assertEqual(self.fpga.output, bytearray())
        self.assertTrue(self.fpga.flushed)

    def test_page_and_sector_addresses_are_range_checked(self):
        with self.assertRaises(ValueError):
            self.host.read_page(-1)
        with self.assertRaises(ValueError):
            self.host.read_page(MAX_IMAGE_SIZE - 1)
        with self.assertRaises(ValueError):
            self.host.erase_sector(MAX_IMAGE_SIZE)

    def test_empty_and_oversized_images_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "must not be empty"):
            validate_image(b"")
        with self.assertRaisesRegex(ValueError, "maximum supported size"):
            validate_image(b"x" * (MAX_IMAGE_SIZE + 1))


if __name__ == "__main__":
    unittest.main()
