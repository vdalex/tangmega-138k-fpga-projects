# Push the local LiteX modifications to the OrangePi BIOS build host.
#
# The two machines must agree exactly: the BIOS is compiled against the CSR map
# and clock frequency the gateware was elaborated with, so any change to the
# target, the platform or the PLL solver has to exist on both sides. Both
# checkouts are at the same commit, so plain file copies are safe.
#
# Symptom of forgetting this: the Pi build fails with something that looks like
# a hardware limit rather than a stale file, e.g.
#   ValueError: No PLL config found (ClkIn=50.00MHz, ClkOut0=187.50MHz,
#                                    ClkOut1=800.00MHz)
# which is really "this tree still has one PLL doing both jobs".

param(
    # The local LiteX checkout (the one litex_setup.py made), the remote login,
    # and the SSH key to reach it with.
    [string]$LitexRoot  = "F:/work/litex",
    # NOT $Remote: the check below collects the remote hashes in $remote, and
    # PowerShell variable names are case-insensitive. A [string] parameter of the
    # same name would flatten that array into one string, and indexing it would
    # then compare single characters against hashes - every file reported as
    # MISMATCH right after being copied successfully.
    [string]$RemoteHost = "orangepi@orangepi5ultra.local",
    [string]$Key        = "$env:USERPROFILE/.ssh/id_ed25519_opi"
)

$key   = $Key
$host_ = $RemoteHost

$files = @(
    # VCO range: the toolchain enforces 650-1300 MHz on GW5AST, not 800-2000.
    @{ src = "$LitexRoot/litex/litex/soc/cores/clock/gowin_gw5a.py"
       dst = "litex/repos/litex/litex/soc/cores/clock/gowin_gw5a.py" },

    # additional_sdc_commands: the Gowin backend had no way to emit a
    # set_false_path at all.
    @{ src = "$LitexRoot/litex/litex/build/gowin/gowin.py"
       dst = "litex/repos/litex/litex/build/gowin/gowin.py" },

    # Second PLL for DDR3 on PLL_L[0], plus the PHY control false paths.
    @{ src = "$LitexRoot/litex-boards/litex_boards/targets/sipeed_tang_mega_138k.py"
       dst = "litex/repos/litex-boards/litex_boards/targets/sipeed_tang_mega_138k.py" },

    # DDR3 IO standards: SSTL15/SSTL15D, per-subsignal, no BANK_VCCIO.
    @{ src = "$LitexRoot/litex-boards/litex_boards/platforms/sipeed_tang_mega_138k.py"
       dst = "litex/repos/litex-boards/litex_boards/platforms/sipeed_tang_mega_138k.py" },

    # Gowin's own DDR3 controller wrapped as a LiteDRAM native port. New file, so
    # the Pi will not have it from the checkout - and without it the BIOS build
    # fails at import rather than at anything that looks like a missing sync.
    @{ src = "$LitexRoot/litex/litex/soc/cores/ram/gowin_ddr3.py"
       dst = "litex/repos/litex/litex/soc/cores/ram/gowin_ddr3.py" }
)

foreach ($f in $files) {
    & scp -i $key -o BatchMode=yes -q $f.src "${host_}:$($f.dst)"
    if ($LASTEXITCODE -ne 0) { Write-Error "failed to copy $($f.src)"; exit 1 }
    Write-Host ("sent  " + (Split-Path $f.src -Leaf) + "  ->  " + $f.dst)
}

# Prove the two sides really match rather than assuming it.
$local = @()
foreach ($f in $files) { $local += (Get-FileHash -Algorithm MD5 $f.src).Hash.ToLower() }
$remote = & ssh -i $key -o BatchMode=yes $host_ ("cd ~ && md5sum " + (($files | ForEach-Object { $_.dst }) -join " ") + " | cut -d' ' -f1")

Write-Host ""
for ($i = 0; $i -lt $files.Count; $i++) {
    $ok = if ($local[$i] -eq $remote[$i]) { "match" } else { "MISMATCH" }
    Write-Host ("{0,-9} {1}" -f $ok, (Split-Path $files[$i].src -Leaf))
}
