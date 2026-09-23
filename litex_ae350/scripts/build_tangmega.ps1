# Build a LiteX SoC for the Sipeed Tang Mega 138K (neo dock) around the
# hardened AndesCore A25 (AE350) that lives in the GW5AST-138C die.
#
# Neither tool is on PATH on this machine, and LiteX finds both with
# shutil.which(), so they are prepended here rather than installed globally:
#
#   gw_sh             the Gowin toolchain, driven headlessly by LiteX
#   riscv-none-elf-*  xPack GCC, for the BIOS
#   programmer_cli    the Gowin programmer, used by --load
#
# Usage:
#   .\build_tangmega.ps1 --build
#   .\build_tangmega.ps1 --build --load
#   .\build_tangmega.ps1 --build --with-ddr3
#
# Anything not recognised below goes straight through to the target script, so
# every LiteX option still works:
#
#   .\build_tangmega.ps1 -Gowin D:\Gowin\... --build --with-gowin-ddr3 ...

# PositionalBinding=$false matters: without it PowerShell binds the first
# pass-through argument positionally to $Gowin, so "--build" silently becomes the
# Gowin install path and every tool then looks missing.
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Gowin   = "F:\Gowin\Gowin_V1.9.11.03_Education_x64",
    [string]$Riscv   = "F:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1",
    [string]$WorkDir = "F:\work\litex\soc",
    [Parameter(ValueFromRemainingArguments)] $Rest
)

$gowin = $Gowin
$riscv = $Riscv

# pip --user drops meson and ninja here, and it is not on PATH by default.
# LiteX needs both: it builds picolibc for the BIOS with Meson.
$pyscripts = "$env:APPDATA\Python\Python311\Scripts"

$env:PATH = "$gowin\IDE\bin;$gowin\Programmer\bin;$riscv\bin;$pyscripts;" + $env:PATH

foreach ($tool in @("gw_sh", "riscv-none-elf-gcc", "meson", "ninja")) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if ($null -eq $found) {
        Write-Error "$tool still not on PATH - check the paths at the top of this script"
        exit 1
    }
    Write-Host ("{0,-20} {1}" -f $tool, $found.Source)
}

# NOT F:\work\litex - that directory contains the cloned repos, and a folder
# named "litex" next to the interpreter's CWD shadows the installed package as
# an empty namespace package. The symptom is a baffling
# "cannot import name get_data_mod from litex (unknown location)".
# The same trap is set by migen/, litedram/ and every other clone.
$work = $WorkDir
if (-not (Test-Path $work)) { New-Item -ItemType Directory $work -Force | Out-Null }
Set-Location $work

# The CPU is the whole point: gowin_ae350 instantiates AE350_SOC as a bare
# device primitive, so no licensed Gowin edition and no IP generation is
# needed. The target already pins the PLL to PLL_R[0], which is what gives
# CORE_CLK its dedicated path - without it the core never gets a clock.
python -m litex_boards.targets.sipeed_tang_mega_138k --cpu-type=gowin_ae350 @Rest
