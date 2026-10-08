param([string]$RtlPath='rtl/backend/rv_pmp.sv',
      [string]$BuildRoot='out/pmp_current_tests',
      [string]$Reference='e9d135b',
      [string]$VerilatorRoot='C:/rv_toolchains/verilator-5.050',
      [string]$W64DevkitRoot='C:/rv_toolchains/w64devkit-2.9.1/w64devkit')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$candidate=(Resolve-Path -LiteralPath $RtlPath).Path
$build=[IO.Path]::GetFullPath($BuildRoot)
foreach($path in @($candidate,$build)){
  if(!$path.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Inputs/output must be inside workspace'}
}
$commit=(& git rev-parse --verify "$Reference^{commit}").Trim()
if($LASTEXITCODE){throw 'Missing frozen reference'}
$gold=(& git show "${commit}:rtl/backend/rv_pmp.sv") -join "`n"
if($LASTEXITCODE){throw 'Missing reference PMP'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No ASCII workspace alias'}
$savedPath=$env:PATH;$savedRoot=$env:VERILATOR_ROOT;$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  $rtl="$drive`:/"+$candidate.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force $run | Out-Null
  [IO.File]::WriteAllText("$run/reference.sv",($gold -replace '\bmodule rv_pmp\b','module rv_pmp_reference'),[Text.UTF8Encoding]::new($false))
  $env:PATH="$W64DevkitRoot/bin;"+$savedPath;$env:VERILATOR_ROOT=$VerilatorRoot
  $report=@{passed=$false;sourceSha256=(Get-FileHash $candidate).Hash;reference=$commit;cases=@();
    scope='Assertion-enabled directed boundaries plus finite all-output binary differential; unit width variants only, NOT full ISA/IEEE-X/STA'}
  foreach($width in @(32,64)){foreach($test in @('rv_pmp_tb','rv_pmp_equiv_tb')){
    $name="${test}_a${width}";$case="$run/$name"
    New-Item -ItemType Directory -Force $case | Out-Null
    $inputs=@('rtl/rv_ooo_pkg.sv',$rtl,"tb/unit/backend/$test.sv")
    if($test -eq 'rv_pmp_equiv_tb'){$inputs+="$run/reference.sv"}
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal -Werror-UNOPTFLAT -Werror-LATCH --top-module $test "-GPADDR_WIDTH=$width" --Mdir $case @inputs *> "$case/compile.log"
    if($LASTEXITCODE){throw "PMP compile failed: $name"}
    & "$W64DevkitRoot/bin/make.exe" -j 2 -C $case -f "V$test.mk" CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$case/build.log"
    if($LASTEXITCODE){throw "PMP build failed: $name"}
    & "$case/V$test.exe" *> "$case/result.log"
    if($LASTEXITCODE -or !(Select-String "$case/result.log" -Pattern 'PASS' -Quiet)){throw "PMP simulation failed: $name"}
    $report.cases+=@{name=$name;passed=$true;exitCode=$LASTEXITCODE}
    $report | ConvertTo-Json -Depth 5 | Set-Content "$run/report.json"
    Get-Content "$case/result.log"
  }}
  $report.passed=$true;$report | ConvertTo-Json -Depth 5 | Set-Content "$run/report.json"
}finally{$env:PATH=$savedPath;$env:VERILATOR_ROOT=$savedRoot;if($pushed){Pop-Location};& subst "$drive`:" /d | Out-Null}
