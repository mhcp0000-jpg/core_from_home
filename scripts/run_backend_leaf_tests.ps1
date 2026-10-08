param([string]$BuildRoot='',
      [string]$SourceRoot='',
      [string]$VerilatorRoot='C:/rv_toolchains/verilator-5.050',
      [string]$W64DevkitRoot='C:/rv_toolchains/w64devkit-2.9.1/w64devkit')
# Native simulator transport/reset tests. FPU test default is the production
# PKG latency: no core hardware -G overrides or synthesis-only settings.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repo}
$sourceFull=(Resolve-Path -LiteralPath $SourceRoot).Path
if($sourceFull -ne $repo -and !$sourceFull.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'SourceRoot must be inside workspace'
}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/backend_leaf_tests'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be below workspace'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$oldPath=$env:PATH;$oldRoot=$env:VERILATOR_ROOT;$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $sourceAlias=("$drive`:/"+$sourceFull.Substring($repo.Length).TrimStart('\').Replace('\','/')).TrimEnd('/')
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  $env:PATH="$W64DevkitRoot/bin;"+$oldPath;$env:VERILATOR_ROOT=$VerilatorRoot
  foreach($test in @(@('rv_phys_regfile_tb','rv_phys_regfile'),@('rv_fpu_tb','rv_fpu'),@('rv_multiplier_tb','rv_multiplier'),@('rv_divider_tb','rv_divider'),@('rv_csr_file_tb','rv_csr_file'))){
    $top,$module=$test;$case="$run/$top"
    New-Item -ItemType Directory -Force $case | Out-Null
    $inputs=@("$sourceAlias/rtl/rv_ooo_pkg.sv","$sourceAlias/rtl/backend/$module.sv","tb/unit/backend/$top.sv")
    @{sources=@($inputs | ForEach-Object {@{path=$_;sha256=(Get-FileHash $_).Hash}});
      coreDefaults=(& "$PSScriptRoot/read_core_config.ps1" -PackagePath "$sourceFull/rtl/rv_ooo_pkg.sv");
      scope='Assertion-enabled directed unit behavior/transport/reset; no independent ISA/STA signoff'} |
      ConvertTo-Json -Depth 6 | Set-Content "$case/manifest.json" -Encoding UTF8
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal -Werror-UNOPTFLAT -Werror-LATCH --top-module $top --Mdir $case @inputs *> "$case/compile.log"
    if($LASTEXITCODE){throw "Compile failed: $top"}
    & "$W64DevkitRoot/bin/make.exe" -j 2 -C $case -f "V$top.mk" CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$case/build.log"
    if($LASTEXITCODE){throw "Build failed: $top"}
    & "$case/V$top.exe" *> "$case/result.log"
    if($LASTEXITCODE -or !(Select-String "$case/result.log" -Pattern 'PASS' -Quiet)){throw "Simulation failed: $top"}
    Get-Content "$case/result.log"
  }
} finally {$env:PATH=$oldPath;$env:VERILATOR_ROOT=$oldRoot;if($pushed){Pop-Location}; & subst "$drive`:" /d | Out-Null}
