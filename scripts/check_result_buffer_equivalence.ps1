param(
  [string]$Baseline='8e2e255',
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite',
  [string]$BuildRoot=''
)
# Whole-module two-state equivalence, including matched payload/pointer state.
# Width/depth variants are explicit test-module defaults, NOT core overrides.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/result_buffer_static_write_proof'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'BuildRoot must be below the repository'
}
$reference=(& git -C $repo show "${Baseline}:rtl/backend/rv_exec_result_buffer.sv") -join "`n"
if($LASTEXITCODE){throw 'Cannot load immutable reference'}
$candidate=Get-Content "$repo/rtl/backend/rv_exec_result_buffer.sv" -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive alias'}
$savedPath=$env:PATH;$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$savedPath
  @{
    baseline=(& git rev-parse $Baseline)
    candidateSha256=(Get-FileHash rtl/backend/rv_exec_result_buffer.sv).Hash
    packageSha256=(Get-FileHash rtl/rv_ooo_pkg.sv).Hash
    yosysSha256=(Get-FileHash "$ToolRoot/bin/yosys.exe").Hash
    configurations='XLEN32/64, DEPTH1/2; other parameter defaults retained'
    scope='All matched output/state bits, equiv_simple seq1 plus equiv_induct undef seq2; two-state, not whole-core ISA proof'
  } | ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($xlen in @(32,64)) {foreach($depth in @(1,2)) {
    $name="x${xlen}_d${depth}"
    foreach($kind in @('gold','gate')) {
      $source=if($kind -eq 'gold'){$reference}else{$candidate}
      $source=$source -replace 'module rv_exec_result_buffer\b',"module $kind"
      $source=$source -replace '(parameter int unsigned XLEN\s*=\s*)32',"`${1}$xlen"
      $source=$source -replace '(parameter int unsigned DEPTH\s*=\s*)1',"`${1}$depth"
      [IO.File]::WriteAllText("$run/${name}_$kind.sv",$source,[Text.UTF8Encoding]::new($false))
    }
    $cmd="read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gold rtl/rv_ooo_pkg.sv $run/${name}_gold.sv; prep -top gold; design -stash ref; " +
      "read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gate rtl/rv_ooo_pkg.sv $run/${name}_gate.sv; prep -top gate; design -stash dut; " +
      'design -copy-from ref gold; design -copy-from dut gate; equiv_make gold gate equiv; hierarchy -top equiv; equiv_simple -seq 1; equiv_induct -undef -seq 2; equiv_status -assert'
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
    if($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'Equivalence successfully proven!' -Quiet)){
      throw "Result buffer equivalence incomplete/failed: $name"
    }
    Write-Output "PASS result buffer complete matched-state/output equivalence $name"
  }}
  # A proof runner must reject a real changed write effect, not just compile.
  $wrong=Get-Content "$run/x32_d2_gate.sv" -Raw
  $enable="tail_q == 1'(slot)"
  if(!$wrong.Contains($enable)){throw 'Negative control write-enable point missing'}
  $wrong=$wrong.Replace($enable,"tail_q != 1'(slot)")
  [IO.File]::WriteAllText("$run/negative_gate.sv",$wrong,[Text.UTF8Encoding]::new($false))
  $cmd="read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gold rtl/rv_ooo_pkg.sv $run/x32_d2_gold.sv; prep -top gold; design -stash ref; " +
    "read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gate rtl/rv_ooo_pkg.sv $run/negative_gate.sv; prep -top gate; design -stash dut; " +
    'design -copy-from ref gold; design -copy-from dut gate; equiv_make gold gate equiv; hierarchy -top equiv; equiv_simple -seq 1; equiv_induct -undef -seq 2; equiv_status -assert'
  & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/negative.log"
  if($LASTEXITCODE -eq 0 -or !(Select-String "$run/negative.log" -Pattern 'ERROR: Found .* unproven' -Quiet)){
    throw 'Incorrect-slot negative control was not rejected by equivalence'
  }
  Write-Output 'PASS result buffer incorrect-slot negative control rejected'
} finally {
  $env:PATH=$savedPath
  if($pushed){Pop-Location}
  & subst "$drive`:" /d | Out-Null
}
