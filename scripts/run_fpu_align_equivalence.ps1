param(
  [string]$Baseline = "bd11890",
  [string]$BuildRoot = "",
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [int]$BuildJobs = 4
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$drive = @("Z", "Y", "X", "W", "U", "T", "S", "R") |
  Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1
if (!$drive) { throw "No unused ASCII drive letter" }
$oldPath = $env:PATH
$oldRoot = $env:VERILATOR_ROOT
try {
  & subst "$drive`:" $repo
  if ($LASTEXITCODE) { throw "subst failed" }
  Push-Location "$drive`:/"
  if (!$BuildRoot) { $BuildRoot="$drive`:/out/fpu_align_equivalence" }
  New-Item -ItemType Directory -Force $BuildRoot | Out-Null
  $ref = & git show "${Baseline}:rtl/backend/rv_fpu.sv"
  if ($LASTEXITCODE) { throw "Cannot read baseline $Baseline" }
  $ref = ($ref -join "`n") -replace "module rv_fpu\b", "module rv_fpu_ref"
  $refPath="$BuildRoot/reference.sv"
  [IO.File]::WriteAllText($refPath,$ref,[Text.UTF8Encoding]::new($false))
  $env:PATH="$W64DevkitRoot/bin;"+$oldPath
  $env:VERILATOR_ROOT=$VerilatorRoot
  foreach ($xlen in @(32,64)) {
    $build="$BuildRoot/x$xlen"
    New-Item -ItemType Directory -Force $build | Out-Null
    $ErrorActionPreference="Continue"
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal --top-module rv_fpu_align_equiv_tb "-GXLEN=$xlen" --Mdir $build rtl/rv_ooo_pkg.sv $refPath rtl/backend/rv_fpu.sv tb/unit/backend/rv_fpu_align_equiv_tb.sv *> "$build/compile.log"
    $code=$LASTEXITCODE
    $ErrorActionPreference="Stop"
    if ($code) { throw "Compile failed: $build/compile.log" }
    $ErrorActionPreference="Continue"
    & "$W64DevkitRoot/bin/make.exe" -j $BuildJobs -C $build -f Vrv_fpu_align_equiv_tb.mk CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$build/build.log"
    $code=$LASTEXITCODE
    $ErrorActionPreference="Stop"
    if ($code) { throw "Build failed: $build/build.log" }
    & "$build/Vrv_fpu_align_equiv_tb.exe" | Tee-Object "$build/result.log"
    if ($LASTEXITCODE) { throw "Alignment equivalence failed" }
  }
} finally {
  if ($drive) { Pop-Location }
  $env:PATH=$oldPath
  $env:VERILATOR_ROOT=$oldRoot
  & subst "$drive`:" /d | Out-Null
}
