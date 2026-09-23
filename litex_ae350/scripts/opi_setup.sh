#!/bin/bash
# Set up a LiteX BIOS build host on the OrangePi 5 Ultra, entirely in $HOME.
#
# The Gowin toolchain is Windows-only here, so the gateware stays on the PC and
# only the BIOS is built on this machine - native make, native POSIX shell, no
# fighting Windows over a Unix Makefile.
#
# Everything lands under ~/litex and nothing needs root: sudo on this box wants
# a password, so meson/ninja come from pip inside a venv and the RISC-V
# compiler comes from the xPack tarball rather than apt.
set -e

ROOT="$HOME/litex"
XPACK_VER="15.2.0-1"
XPACK="xpack-riscv-none-elf-gcc-${XPACK_VER}"
XPACK_URL="https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${XPACK_VER}/${XPACK}-linux-arm64.tar.gz"

mkdir -p "$ROOT"
cd "$ROOT"

# ---- RISC-V toolchain ------------------------------------------------------
# Deliberately the same xPack version as the Windows side, so both machines
# compile the BIOS with the identical compiler.
if [ ! -d "$ROOT/$XPACK" ]; then
    echo "=== downloading $XPACK (linux-arm64) ==="
    curl -sSL -o xpack.tar.gz "$XPACK_URL"
    tar xzf xpack.tar.gz
    rm -f xpack.tar.gz
fi
export PATH="$ROOT/$XPACK/bin:$PATH"
riscv-none-elf-gcc --version | head -1

# ---- Python environment ----------------------------------------------------
if [ ! -d "$ROOT/venv" ]; then
    echo "=== creating venv ==="
    python3 -m venv "$ROOT/venv"
fi
. "$ROOT/venv/bin/activate"
python -m pip -q install --upgrade pip setuptools wheel
python -m pip -q install meson ninja
echo "meson $(meson --version), ninja $(ninja --version)"

# ---- LiteX -----------------------------------------------------------------
# Same flow as the PC so the SoC elaborates identically and the CSR map the
# BIOS is compiled against matches the one baked into the gateware.
if [ ! -f "$ROOT/litex_setup.py" ]; then
    curl -sSL -o "$ROOT/litex_setup.py" \
        https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py
fi

# Run it from a subdirectory: a folder named "litex" beside the interpreter's
# CWD shadows the installed package as an empty namespace package, and the
# symptom is a baffling "cannot import name get_data_mod from litex".
mkdir -p "$ROOT/repos"
cd "$ROOT/repos"
python "$ROOT/litex_setup.py" --init --install --config full -y

echo "=== versions ==="
python -c "import litex, migen; print('litex', litex.__version__)" 2>/dev/null || true
python -c "import litex_boards; print('litex_boards OK')"
echo "=== setup complete ==="
