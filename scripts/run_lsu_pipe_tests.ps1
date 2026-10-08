param(
  [string]$VerilatorRoot='C:/rv_toolchains/verilator-5.050',
  [string]$W64DevkitRoot='C:/rv_toolchains/w64devkit-2.9.1/w64devkit',
  [string]$BuildRoot='',
  [string]$RtlPath=''
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$RtlPath){$RtlPath=Join-Path $repo 'rtl/backend/rv_lsu_pipe.sv'}
$rtlFull=(Resolve-Path -LiteralPath $RtlPath).Path
if(!$rtlFull.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate source must stay below workspace'}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/lsu_pipe_tests'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be below workspace'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive alias'}
$savedPath=$env:PATH;$savedRoot=$env:VERILATOR_ROOT
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $root="$drive`:/";$run=$root+$build.Substring($repo.Length+1).Replace('\','/')
  $rtlMapped=$root+$rtlFull.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$W64DevkitRoot/bin;"+$savedPath;$env:VERILATOR_ROOT=$VerilatorRoot
  @{sourceSha256=(Get-FileHash $rtlFull).Hash;sourcePath=$rtlFull;
    scope='Asserted directed depth1 + randomized depth2 + XLEN32/64 x DEPTH1/2 payload queue reference model'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($top in @('rv_lsu_pipe_tb','rv_lsu_pipe_depth2_tb','rv_lsu_pipe_widths_tb')){
    $case="$run/$top";New-Item -ItemType Directory -Force -Path $case | Out-Null
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal -Werror-UNOPTFLAT --top-module $top --Mdir $case `
      "${root}rtl/rv_ooo_pkg.sv" $rtlMapped "${root}tb/unit/backend/$top.sv" *> "$case/compile.log"
    if($LASTEXITCODE){throw "Code generation failed: $top"}
    & "$W64DevkitRoot/bin/make.exe" -j 2 -C $case -f "V$top.mk" VM_PARALLEL_BUILDS=1 CXX=g++ CC=gcc LINK=g++ *> "$case/build.log"
    if($LASTEXITCODE){throw "Build failed: $top"}
    & "$case/V$top.exe" *> "$case/result.log"
    if($LASTEXITCODE -or !(Select-String "$case/result.log" -Pattern 'PASS' -Quiet) -or (Select-String "$case/result.log" -Pattern 'FAIL' -Quiet)){throw "Test failed: $top"}
    Get-Content "$case/result.log"
  }
}finally{
  $env:PATH=$savedPath;$env:VERILATOR_ROOT=$savedRoot
  & subst "$drive`:" /d | Out-Null
}
