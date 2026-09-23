#!/bin/bash
# BIOS for the variant with 256 KiB of main RAM in block RAM.
# No DDR3: litedram's Gowin PHY cannot reach a legal DDR3 frequency on this
# board (200 MT/s at the default sys clock, and the fabric will not close
# timing high enough to fix that), so main memory comes from BSRAM instead.
set -e
ROOT="$HOME/litex"
export PATH="$ROOT/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH"
. "$ROOT/venv/bin/activate"
mkdir -p "$ROOT/soc-bram"
cd "$ROOT/soc-bram"
python -m litex_boards.targets.sipeed_tang_mega_138k \
    --cpu-type=gowin_ae350 --integrated-main-ram-size 0x40000 \
    --build --no-compile-gateware
echo "=== bios ==="
ls -l "$ROOT/soc-bram/build/sipeed_tang_mega_138k/software/bios/bios.bin"
grep "memory_region" "$ROOT/soc-bram/build/sipeed_tang_mega_138k/csr.csv"
