# AWS F2 harness (Task B) - in progress

Nothing here has run on AWS; nothing is set up there without the owner's go-ahead (ROADMAP.md, Task B,
where the harness designs are compared).

| file | what it is |
|---|---|
| `mem_lane.sv` | one decoder lane that works from memory: a job (file address and length, output area) is read with an AXI4 read master, decoded by the wide core (`jpeg_decoder FAST=2`, RGB) and written as 16-byte records {x, y, 4 x RGB} with an AXI4 write master; reports clocks, input / output waits, pixels, records, error bits and a position-binding hash of the pixels |
| `sim/tb_mem_lane.cpp` | Verilator testbench: an AXI4 memory model with random delays and random gaps on every channel; reads the records back, places every pixel by x and y (each exactly once), compares it with the golden image and recomputes the hash |
| `sim/run_lane_tests.py` | every supported corpus file with and without 30 % gaps, plus photos (golden: libjpeg 9e `djpeg -dct int -nosmooth`) |

```sh
cd boards/aws_f2/sim && make && python3 run_lane_tests.py --photos ../../../test_images/adapter.jpg
```
