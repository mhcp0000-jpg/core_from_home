param(
  [string]$Baseline = "8f1c6ba",
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [int]$BuildJobs = 4,
  [ValidateSet("alu", "divider", "multiplier", "wb", "iq")]
  [string[]]$OnlyCases = @("alu", "divider", "multiplier", "wb", "iq"),
  [string]$BuildRoot = "out/timing_equivalence"
)
# Compare interfaces and cycle timing against an immutable git checkpoint.
# Generated reference RTL and build artifacts remain under ignored out/.
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$drive = (@("R", "S", "T", "U", "W", "X", "Y", "Z") | Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1)
if (!$drive) { throw "No unused drive letter available" }
$oldPath = $env:PATH
$oldRoot = $env:VERILATOR_ROOT
try {
  & subst "$drive`:" $repoRoot
  if ($LASTEXITCODE) { throw "subst failed" }
  $env:PATH = "$W64DevkitRoot\bin;" + $oldPath
  $env:VERILATOR_ROOT = $VerilatorRoot
  $root = "$drive`:/"
  Push-Location $root
  $cases = @(@("alu", "rv_int_alu"), @("divider", "rv_divider"), @("multiplier", "rv_multiplier"), @("wb", "rv_writeback_arbiter"), @("iq", "rv_issue_queue"))
  foreach ($case in $cases) {
    $name, $module = $case
    if ($name -notin $OnlyCases) { continue }
    $build = "${root}$($BuildRoot.Replace('\','/').TrimEnd('/'))/$name"
    New-Item -ItemType Directory -Force $build | Out-Null
    $reference = & git -C $repoRoot show "${Baseline}:rtl/backend/$module.sv"
    if ($LASTEXITCODE) { throw "Cannot read baseline $Baseline/$module" }
    $reference = ($reference -join "`n") -replace "module $module\b", "module ${module}_timing_ref"
    $refPath = "$build/reference.sv"
    [IO.File]::WriteAllText($refPath, $reference, [Text.UTF8Encoding]::new($false))
    $top = "rv_${name}_equiv_tb"
    $ErrorActionPreference = "Continue" # Windows PowerShell treats native stderr warnings as errors.
    # Baseline MUL's stall SVA lacks a flush exception: arbitrary flush fuzzing
    # trips it in BOTH designs. This run uses explicit all-output equality
    # checks; normal block/integration/SoC regressions separately enable SVA.
    & "$VerilatorRoot\bin\verilator_bin.exe" --cc --exe --main --timing -DSYNTHESIS --output-split 2000 -Wno-fatal --top-module $top --Mdir $build "${root}rtl/rv_ooo_pkg.sv" $refPath "${root}rtl/backend/$module.sv" "${root}tb/unit/backend/rv_${name}_timing_equiv_tb.sv" *> "$build/compile.log"
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE) { throw "$name generation failed: $build/compile.log" }
    $ErrorActionPreference = "Continue"
    & "$W64DevkitRoot\bin\make.exe" -j $BuildJobs -C $build -f "V$top.mk" CXX=g++ CC=gcc LINK=g++ *> "$build/build.log"
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE) { throw "$name build failed: $build/build.log" }
    & "$build/V$top.exe" | Tee-Object "$build/result.log"
    if ($LASTEXITCODE) { throw "$name equivalence failed" }
  }
} finally {
  if ($root) { Pop-Location }
  $env:PATH = $oldPath
  $env:VERILATOR_ROOT = $oldRoot
  & subst "$drive`:" /d | Out-Null
}
