# Build all tests (assembler + golden model) and run each one on the RTL.
#
#   .\scripts\run_tests.ps1                 # Icarus Verilog (fast)
#   .\scripts\run_tests.ps1 -Sim xsim       # Vivado xsim
#   .\scripts\run_tests.ps1 -Only matmul    # tests whose name contains "matmul"
#   .\scripts\run_tests.ps1 -Random 50      # number of random tests (default 20)
#   .\scripts\run_tests.ps1 -NoBuild        # skip the test build
#   .\scripts\run_tests.ps1 -Cores 1        # a GPU with 1 shader core (default 2)
#   .\scripts\run_tests.ps1 -Sched gto      # greedy-then-oldest warp scheduler (default lrr)
#
# Exit code 0 means every test passed.
param(
    [ValidateSet("icarus", "xsim")] [string]$Sim = "icarus",
    [string]$Only = "",
    [int]$Random = 20,
    [switch]$NoBuild,
    [ValidateRange(1, 4)] [int]$Cores = 2,
    [ValidateSet("lrr", "gto")] [string]$Sched = "lrr"
)
$schedNum = if ($Sched -eq "gto") { 1 } else { 0 }
$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
$tests  = Join-Path $root "build\tests"
$simdir = Join-Path $root "build\sim_${Sim}_c${Cores}_$Sched"
New-Item -ItemType Directory -Force $simdir | Out-Null

# ---- 1. build the tests ------------------------------------------------------
if (-not $NoBuild) {
    if (Test-Path $tests) { Remove-Item -Recurse -Force $tests }
    python (Join-Path $root "tools\build_tests.py") --random $Random
    if ($LASTEXITCODE -ne 0) { Write-Output "test build failed"; exit 1 }
}

# ---- 2. compile the hardware once --------------------------------------------
$inc     = Join-Path $root "rtl\core"
$sources = @(Get-ChildItem (Join-Path $root "rtl\core\*.v") | ForEach-Object FullName) +
           @(Get-ChildItem (Join-Path $root "rtl\gpu\*.v") | ForEach-Object FullName) +
           (Join-Path $root "dv\tb_gpu.sv")

Push-Location $simdir
try {
    if ($Sim -eq "icarus") {
        $env:PATH = "E:\tools\oss-cad-suite\bin;E:\tools\oss-cad-suite\lib;$env:PATH"
        iverilog -g2012 -Wall -Wno-timescale -I $inc -P tb_gpu.NC=$Cores -P tb_gpu.SCHED=$schedNum -o sim.vvp @sources
        if ($LASTEXITCODE -ne 0) { exit 1 }
    } else {
        # Claude's shell sets this, and it stops Vivado's .bat tools from
        # finding their helpers. A normal shell does not have it.
        Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
        $viv = "C:\Xilinx\Vivado\2021.1\bin"
        & "$viv\xvlog.bat" -sv -i $inc @sources | Out-Null
        if ($LASTEXITCODE -ne 0) { Get-Content xvlog.log; exit 1 }
        & "$viv\xelab.bat" tb_gpu -generic_top "NC=$Cores" -generic_top "SCHED=$schedNum" -s tb_gpu_sim | Out-Null
        if ($LASTEXITCODE -ne 0) { Get-Content xelab.log; exit 1 }
    }

    # ---- 3. run every test ---------------------------------------------------
    $pass = 0; $fail = @()
    foreach ($dir in Get-ChildItem $tests -Directory | Where-Object Name -like "*$Only*") {
        $name = $dir.Name
        foreach ($f in "prog.hex", "mem.hex", "expect.hex", "launch.hex") {
            Copy-Item (Join-Path $dir.FullName $f) $simdir -Force
        }
        if ($Sim -eq "icarus") {
            $log = vvp -n sim.vvp
        } else {
            $log = & "$viv\xsim.bat" tb_gpu_sim -R
        }
        $stats  = ($log | Select-String "^cycles=" | Select-Object -First 1).Line
        $result = ($log | Select-String "^TEST " | Select-Object -First 1).Line
        if ($result -eq "TEST PASSED") {
            $pass++
            Write-Output ("PASS  {0,-14} {1}" -f $name, $stats)
        } else {
            $fail += $name
            Write-Output ("FAIL  {0,-14} {1}" -f $name, $stats)
            $log | Select-String "ERROR|MISMATCH" | Select-Object -First 5 | ForEach-Object { "      $($_.Line)" }
        }
    }
} finally {
    Pop-Location
}

Write-Output ""
Write-Output "$pass passed, $($fail.Count) failed (Sim=$Sim, Cores=$Cores, Sched=$Sched)"
if ($fail.Count -gt 0) { Write-Output "failed: $($fail -join ', ')"; exit 1 }
exit 0
