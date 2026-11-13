# Yosys synthesis to the IHP SG13G2 (130 nm open PDK) standard cells, for
# gate counts and area of each block. No placement, no timing: the area is
# the sum of the cell areas from the Liberty file.
#
#   .\synth\run_sg13g2.ps1 [-Lib <path to sg13g2_stdcell_typ_1p20V_25C.lib>]
#
# The Liberty file is part of the IHP open PDK (github.com/IHP-GmbH/IHP-Open-PDK,
# ihp-sg13g2/libs.ref/sg13g2_stdcell/lib). It is not in this repository.
param(
    [string]$Lib = "E:\tinytrust\synth\lib\sg13g2_stdcell_typ_1p20V_25C.lib",
    [string[]]$Tops = @("fma32", "alu", "l1_cache", "lsu", "sm_core")
)
# Continue: Yosys writes warnings to stderr, and PowerShell 5.1 would stop on them.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root "synth\reports"
New-Item -ItemType Directory -Force $out | Out-Null
$env:PATH = "E:\tools\oss-cad-suite\bin;E:\tools\oss-cad-suite\lib;$env:PATH"
$lib = $Lib -replace '\\', '/'
$src = (@(Get-ChildItem (Join-Path $root "rtl\core\*.v")) | ForEach-Object { $_.FullName -replace '\\', '/' }) -join " "
$inc = (Join-Path $root "rtl\core") -replace '\\', '/'

foreach ($top in $Tops) {
    $ys = Join-Path $out "sg13g2_$top.ys"
    @"
read_verilog -I$inc $src
hierarchy -check -top $top
synth -top $top -flatten
dfflibmap -liberty $lib
abc -liberty $lib
setundef -zero
opt_clean -purge
tee -o $($out -replace '\\','/')/sg13g2_${top}_stat.txt stat -liberty $lib
"@ | Set-Content -Encoding ascii $ys
    Write-Output "== $top"
    yosys -q -l (Join-Path $out "sg13g2_$top.log") -s $ys 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Output "yosys failed for $top"; exit 1 }
    Select-String -Path (Join-Path $out "sg13g2_${top}_stat.txt") -Pattern "Chip area|Number of cells|cells$|sequential" |
        ForEach-Object { "   " + $_.Line.Trim() }
}
