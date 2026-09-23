#!/bin/bash
# BIOS for the variant whose main memory is DDR3 through Gowin's own controller.
#
# The netlist path is deliberately not passed here: it only lands on the Gowin
# file list, which this build does not use, and it lives on the Windows side
# anyway. What has to match the gateware build is the CSR and memory map, and
# that depends on --cpu-type and --with-gowin-ddr3 only.
#
# Extra arguments are passed through, which is how the diagnostic variant is
# built: adding --integrated-main-ram-size 0x40000 leaves main_ram in block RAM
# and moves DDR3 to a region of its own, so the BIOS reaches a console even when
# the controller is not answering.
set -e
ROOT="$HOME/litex"
export PATH="$ROOT/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH"
. "$ROOT/venv/bin/activate"
mkdir -p "$ROOT/soc-gwddr3"
cd "$ROOT/soc-gwddr3"
python -m litex_boards.targets.sipeed_tang_mega_138k \
    --cpu-type=gowin_ae350 --with-gowin-ddr3 \
    --build --no-compile-gateware "$@"
echo "=== bios ==="
ls -l "$ROOT/soc-gwddr3/build/sipeed_tang_mega_138k/software/bios/bios.bin"
grep "memory_region" "$ROOT/soc-gwddr3/build/sipeed_tang_mega_138k/csr.csv"
