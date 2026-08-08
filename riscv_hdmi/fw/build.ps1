# Build the AE350 firmware without make (this machine has no MSYS2).
#
#   powershell -ExecutionPolicy Bypass -File build.ps1
#
# Produces firmware.elf/.bin and ../eda_proj/src/boot_rom.vh, which the FPGA
# build reads with $readmemh - so the program ends up inside the bitstream.
# Re-run the Gowin build afterwards to pick up a new firmware image.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$TC    = "F:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf"
$ARCH  = @("-march=rv32imac_zicsr", "-mabi=ilp32")
$FLAGS = @("-Os", "-g", "-ffreestanding", "-fno-builtin",
           "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra")

Write-Host "[1/5] start.S"
& "$TC-gcc" @ARCH @FLAGS -c start.S -o start.o

Write-Host "[2/5] main.c"
& "$TC-gcc" @ARCH @FLAGS -c main.c -o main.o

Write-Host "[3/5] link"
# PowerShell parses a bare -Wl,... token as a parameter list and errors out
# ("Missing argument in parameter list"), so pass the link options as strings.
$LDFLAGS = @("-nostdlib", "-nostartfiles", "-T", "ae350.ld",
             "-Wl,--gc-sections", "-Wl,-Map=firmware.map")
& "$TC-gcc" @ARCH @FLAGS @LDFLAGS start.o main.o -o firmware.elf
& "$TC-size" firmware.elf

Write-Host "[4/5] objcopy"
& "$TC-objcopy" -O binary firmware.elf firmware.bin

Write-Host "[5/5] ROM image"
python ..\tools\bin2vh.py firmware.bin ..\eda_proj\src\boot_rom.vh --words 4096

Write-Host "done - now rebuild the Gowin project to bake it into the bitstream."
