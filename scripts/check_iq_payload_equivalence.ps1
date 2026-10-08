param(
  [string]$Baseline='8e2e255',
  [string]$SourceRoot='',
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite',
  [string]$BuildRoot=''
)
# Whole IQ state/output equivalence, not an ISA proof. Explicit test variants
# do not change production core settings. Every configuration must prove.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repo}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/iq_payload_formal'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'BuildRoot must be inside workspace'
}
$reference=(& git -C $repo show "${Baseline}:rtl/backend/rv_issue_queue.sv") -join "`n"
if($LASTEXITCODE){throw 'Missing immutable IQ reference'}
$candidate=Get-Content "$SourceRoot/rtl/backend/rv_issue_queue.sv" -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No available ASCII drive alias'}
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
    candidateSha256=(Get-FileHash "$SourceRoot/rtl/backend/rv_issue_queue.sv").Hash
    packageSha256=(Get-FileHash rtl/rv_ooo_pkg.sv).Hash
    scope='All matched state/outputs; equiv_simple short seq1, equiv_induct undef seq2; two-state'
    configurations='ENTRIES4/7/56 at XLEN32; ENTRIES7 at XLEN64; no core overrides'
  } | ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($cfg in @(@(32,4),@(32,7),@(32,56),@(64,7))) {
    $xlen,$entries=$cfg;$name="x${xlen}_e${entries}"
    foreach($kind in @('gold','gate')) {
      $source=if($kind -eq 'gold'){$reference}else{$candidate}
      $source=$source -replace 'module rv_issue_queue\b',"module $kind"
      $source=$source -replace '(parameter int unsigned XLEN\s*=\s*)32',"`${1}$xlen"
      $source=$source -replace '(parameter int unsigned ENTRIES\s*=\s*)24',"`${1}$entries"
      [IO.File]::WriteAllText("$run/${name}_${kind}.sv",$source,[Text.UTF8Encoding]::new($false))
    }
    $cmd="read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gold rtl/rv_ooo_pkg.sv $run/${name}_gold.sv; prep -top gold; design -stash ref; " +
      "read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gate rtl/rv_ooo_pkg.sv $run/${name}_gate.sv; prep -top gate; design -stash dut; " +
      'design -copy-from ref gold; design -copy-from dut gate; equiv_make gold gate equiv; hierarchy -top equiv; equiv_struct -fwd -icells; equiv_simple -short -seq 1; equiv_induct -undef -seq 2; equiv_status -assert'
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
    if($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'Equivalence successfully proven!' -Quiet)){
      throw "IQ equivalence failed/incomplete: $name"
    }
    Write-Output "PASS IQ matched state/output equivalence $name"
  }
  $wrong=Get-Content "$run/x32_e4_gate.sv" -Raw
  $enable='candidate_valid_o[slot]        = am_found[slot] &&'
  if(!$wrong.Contains($enable)){throw 'Negative-control mutation point missing'}
  $wrong=$wrong.Replace($enable,'candidate_valid_o[slot]        = !am_found[slot] &&')
  [IO.File]::WriteAllText("$run/negative_gate.sv",$wrong,[Text.UTF8Encoding]::new($false))
  $cmd="read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gold rtl/rv_ooo_pkg.sv $run/x32_e4_gold.sv; prep -top gold; design -stash ref; " +
    "read_slang --std 1800-2017 --ignore-assertions --ignore-initial --no-implicit-memories --top gate rtl/rv_ooo_pkg.sv $run/negative_gate.sv; prep -top gate; design -stash dut; " +
    'design -copy-from ref gold; design -copy-from dut gate; equiv_make gold gate equiv; hierarchy -top equiv; equiv_struct -fwd -icells; equiv_simple -short -seq 1; equiv_induct -undef -seq 2; equiv_status -assert'
  & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/negative.log"
  if($LASTEXITCODE -eq 0 -or !(Select-String "$run/negative.log" -Pattern 'ERROR: Found .* unproven' -Quiet)){
    throw 'Incorrect candidate-valid negative control was not rejected'
  }
  Write-Output 'PASS IQ incorrect valid negative control rejected'
} finally {
  $env:PATH=$savedPath
  if($pushed){Pop-Location}
  & subst "$drive`:" /d | Out-Null
}
