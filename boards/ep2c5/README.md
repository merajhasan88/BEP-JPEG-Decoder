# Cyclone II EP2C5T144C8 board (Quartus II 13.0sp1)

The common "EP2C5 mini board": EP2C5T144C8 (4,608 LEs, 26 M4K blocks, 13 18x18 multipliers),
50 MHz oscillator, 3 LEDs, one button, EPCS4 flash, USB-Blaster JTAG. Quartus II 13.0sp1 Web
Edition is the last version that supports Cyclone II; put its `bin` folder on `PATH`.

| folder | contents |
|---|---|
| `rtl/` | board tops (Intel/Altera-specific parts: PLL, clock control, virtual JTAG): `fpga_top.sv` (ROM -> decoder -> UART, checksum LED, watchdog; `BENCH=1` clock-count report, `PLL_MUL`/`PLL_DIV` core clock), `jpeg_rom.sv`, `uart_tx.sv`, `fpga_jtag_top.sv` + `jtag_stream_core.sv` (JPEG in over JTAG, decoder clock gated, checksum and clock count read back) |
| `fpga*/` | Quartus projects (below); each ROM build carries the checksum of its own test image for the self-check LED |
| `scripts/` | `jtag_decode.py` + `jtag_stream.tcl` (stream any JPEG over the USB-Blaster to `fpga_jtag`), `uart_capture.py` (save a frame from the UART demo), `uart_bench.py` (`BENCH=1` report) |
| `sim/` | board-level simulations: `run_board_sim.sh` (whole `fpga_top` design, UART decoded in `tb_fpga.cpp`), `make jtag` (the JTAG harness with the gated clock modelled) |
| `compile_all.sh`, `sta_paths.tcl` | compile every project in turn and summarise fit and timing; list the worst timing paths |

## Builds

Every build includes the full header/table validation (`CHECKS=1`) and the 13-bit `err`
(re-fitted 2026-10-04). All use 13/13 multipliers (26 9-bit elements).

| project | options | LEs | M4K | Fmax | row buffer / max width |
|---|---|---:|---:|---:|---|
| `fpga` | compact core, MCU order, replication, RGB (= djpeg 9e) | 3,469 (75 %) | 9 | 59.7 MHz | none needed / any |
| `fpga_raster_box` | compact, raster, replication, RGB | 4,132 (90 %) | 25 | 62.8 MHz | 9,216 B / 4:2:0 384 px |
| `fpga_raster_ycc` | compact, raster, Pillow smoothing, YCbCr only | 4,358 (95 %) | 25 | 58.0 MHz | 9,216 B / 4:2:0 352 px |
| `fpga_raster` | compact, raster, Pillow smoothing, RGB (= Pillow) | 4,587 (100 %) | 25 | 60.5 MHz | 9,216 B / 4:2:0 352 px |

Fast core (`FAST=1`), MCU order, replication, RGB:

| project | clock | LEs | memory | timing |
|---|---|---:|---:|---|
| `fpga_jtag` | **95 MHz from the PLL**; the JPEG is streamed in over the USB-Blaster (virtual JTAG), the decoder clock only runs while its next byte is waiting, so the on-chip clock count is the decode time without streaming time | 4,481 (97 %) | 59,712 bits | met at 95 MHz, +0.45 ns setup, +0.50 ns hold (Fmax 99.2 MHz); PowerPlay ~147 mW (2026-10-04) |
| `fpga_fast_bench` | **95 MHz from the PLL** (`PLL_MUL=19`, `PLL_DIV=10`), `BENCH=1` (decodes at full speed, reports the clock count over UART) | 4,420 (96 %) | 63,808 bits | met at 95 MHz, +0.55 ns (Fmax 100.2 MHz); PowerPlay ~151 mW (2026-10-04) |
| `fpga_fast` | 50 MHz, pixels over UART like `fpga` (the board demo) | 4,433 (96 %) | 63,808 bits | met at 50 MHz, +6.55 ns (Fmax 74.3 MHz) |

The compact builds meet timing at 50 MHz. What made the largest build fit: the Huffman symbol
table folded into one M4K, the coefficient buffer zeroed during the IDCT's second pass, the
smoothing filter reduced to one formula `(3*cs[i] + cs[neighbour] + bias) >> 4` shared by all
sampling modes, geometry derived by shifts, and Quartus's area optimisation. Without
`(* ramstyle = "M4K" *)` Quartus silently moved a 1 KB RAM into ~750 LEs when M4K blocks got tight.

## Build, program, run

```sh
cd boards/ep2c5/fpga_jtag && quartus_sh --flow compile jpeg_fpga_jtag     # ~9 min
quartus_pgm -m jtag -o "p;output_files/jpeg_fpga_jtag.sof"                # USB-Blaster, volatile
python3 ../scripts/jtag_decode.py photo.jpg ...    # stream each file, read decoder clocks + checksum
#   the reference checksum comes from libjpeg 9e (bench/tools.py builds it; or --djpeg PATH)
cd ../fpga_raster && quartus_sh --flow compile jpeg_fpga_raster                          # UART demo
quartus_pgm -m jtag -o "p;output_files/jpeg_fpga_raster.sof"
./compile_all.sh                                   # every project, one after another
```

On the board (2026-10-01 and 2026-10-04, `fpga_jtag` at 95 MHz): every test photo decodes with libjpeg's checksum
and exactly the simulated clock count, e.g. a 2048x1365 4:2:0 photo in 2,847,577 clocks = 29.97 ms,
3120x4160 4:2:2 (`test_images/adapter.jpg`) in 19,234,181 clocks = 202.5 ms; the 26 malformed
files of `tb/malformed` end with the expected error bits (`bench/board_jtag_95mhz_2026-10-0*.txt`: 73/73 on
2026-10-04 including the owner's 12 photos, then 62/62 with the RTL portability fixes).

**A different ROM image** (ROM demos hold at most 1,024 bytes):
`scripts/jpeg_to_hex.py img.jpg jpeg_rom.hex 1024` (from the repository root), then set
`ROM_LENGTH` and `EXPECTED_CHK` (from `scripts/pnm_checksum.py golden.pnm`) in the `.qsf`.
`set_parameter` values must be plain **decimal** integers: Quartus 13 turns a Verilog literal such
as `32'hD49C70EF` into a string without any warning.

**Pins**: `clk` PIN_17 (50 MHz), `key_n` PIN_144 (reset button), `led_n[0..2]` PIN_3/7/9 (toggles
with every frame / checksum OK / error), `uart_tx` PIN_41 (3.3 V -> RXD of a USB-serial adapter).
Serial (115200 baud): `A5 5A 'J' 'P' 'G' W H`, then `X Y C0 C1 C2` per pixel, then `'E' 'N' 'D'`,
repeated every 1.5 s; `scripts/uart_capture.py /dev/ttyUSB0 out.ppm` saves a frame. The checksum
LED alone proves the decode on the board; the UART only shows the picture.

The USB-Blaster enumerates most reliably with the board powered first and the cable plugged
straight into the computer. On Linux without root, add
`SUBSYSTEM=="usb", ATTR{idVendor}=="09fb", ATTR{idProduct}=="6001", MODE="0666"` to
`/etc/udev/rules.d/51-usbblaster.rules`.
