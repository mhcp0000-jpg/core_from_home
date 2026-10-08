param(
  [string]$VerilatorRoot='C:/rv_toolchains/verilator-5.050',
  [string]$W64DevkitRoot='C:/rv_toolchains/w64devkit-2.9.1/w64devkit',
  [string]$BuildRoot=''
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/result_buffer_width_tests'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'BuildRoot must be below repository'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive alias'}
$savedPath=$env:PATH;$savedRoot=$env:VERILATOR_ROOT
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $root="$drive`:/"
  $run=$root+$build.Substring($repo.Length+1).Replace('\','/')
  $env:PATH="$W64DevkitRoot/bin;"+$savedPath
  $env:VERILATOR_ROOT=$VerilatorRoot
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  @{
    bufferSha256=(Get-FileHash "$repo/rtl/backend/rv_exec_result_buffer.sv").Hash
    packageSha256=(Get-FileHash "$repo/rtl/rv_ooo_pkg.sv").Hash
    scope='DEPTH2, XLEN32/64 explicit test instances, 200000 randomized cycles each, assertions enabled'
  } | ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($width in @(32,64)){
    $top="rv_result_buffer${width}_tb";$case="$run/x$width"
    New-Item -ItemType Directory -Force -Path $case | Out-Null
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal --top-module $top --Mdir $case `
      "${root}rtl/rv_ooo_pkg.sv" "${root}rtl/backend/rv_exec_result_buffer.sv" `
      "${root}tb/unit/backend/rv_exec_result_buffer_depth2_tb.sv" "${root}tb/unit/backend/rv_exec_result_buffer_widths_tb.sv" *> "$case/compile.log"
    if($LASTEXITCODE){throw "Verilator code generation failed XLEN$width"}
    # Compile generated translation units directly; do not depend on the
    # Windows includer.bat finding Python in a user's global PATH.
    & "$W64DevkitRoot/bin/make.exe" -j 4 -C $case -f "V$top.mk" VM_PARALLEL_BUILDS=1 CXX=g++ CC=gcc LINK=g++ *> "$case/build.log"
    if($LASTEXITCODE){throw "Native build failed XLEN$width"}
    & "$case/V$top.exe" *> "$case/result.log"
    if($LASTEXITCODE){throw "Result buffer randomized/SVA check failed XLEN$width"}
    Get-Content "$case/result.log"
  }
} finally {
  $env:PATH=$savedPath;$env:VERILATOR_ROOT=$savedRoot
  & subst "$drive`:" /d | Out-Null
}
