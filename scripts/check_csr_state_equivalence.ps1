param([Parameter(Mandatory=$true)][string]$RtlPath,
      [Parameter(Mandatory=$true)][string]$BuildRoot,
      [string]$Reference='e9d135b',
      [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite')
# All matched original CSR public outputs/state transitions, arbitrary inputs,
# undef-aware synthesis equivalence. Not IEEE procedural X/ISA/privilege signoff.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$candidate=(Resolve-Path -LiteralPath $RtlPath).Path
$build=[IO.Path]::GetFullPath($BuildRoot)
foreach($path in @($candidate,$build)){
  if(!$path.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source/output must stay below workspace'}
}
$commit=(& git rev-parse --verify "$Reference^{commit}").Trim()
if($LASTEXITCODE){throw 'Missing immutable reference'}
$gold=(& git show "${commit}:rtl/backend/rv_csr_file.sv") -join "`n"
if($LASTEXITCODE){throw 'Cannot read reference'}
$source=Get-Content -LiteralPath $candidate -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No ASCII workspace alias'}
$savedPath=$env:PATH;$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$savedPath
  [IO.File]::WriteAllText("$run/reference.sv",($gold -replace '\bmodule rv_csr_file\b','module rv_csr_file_reference'),[Text.UTF8Encoding]::new($false))
  Copy-Item -LiteralPath $candidate -Destination "$run/candidate.sv"
  Copy-Item rtl/rv_ooo_pkg.sv "$run/pkg.sv"
  $badTarget='mtval_q <= trap_tval_i;'
  if(!$source.Contains($badTarget)){throw 'Negative control target missing'}
  [IO.File]::WriteAllText("$run/negative.sv",$source.Replace($badTarget,"mtval_q <= trap_tval_i ^ XLEN'(1);"),[Text.UTF8Encoding]::new($false))
  $report=@{passed=$false;reference=$commit;sourceSha256=(Get-FileHash $candidate).Hash;
    packageSha256=(Get-FileHash rtl/rv_ooo_pkg.sv).Hash;cases=@();
    scope='All matched original output/state transition synthesis equivalence, undef-aware, no protocol constraints; NOT independent ISA/IEEE 4-state/STA'}
  foreach($cfg in @(@(32,32,8,0),@(64,56,8,0),@(32,32,4,1),@(64,64,16,1),@(32,32,8,0))){
    $width,$address,$pmp,$smode=$cfg;$negative=$report.cases.Count -eq 4
    $name="w${width}_a${address}_p${pmp}_s${smode}"+$(if($negative){'_negative'}else{''})
    $leafVariant="-G XLEN=$width -G PADDR_WIDTH=$address -G PMP_ENTRIES=$pmp -G HAS_SMODE=$smode"
    $front='read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --no-implicit-memories'
    $input=if($negative){'negative.sv'}else{'candidate.sv'}
    $command="$front --top rv_csr_file_reference $leafVariant $run/pkg.sv $run/reference.sv; $front --top rv_csr_file $leafVariant $run/pkg.sv $run/$input; proc; opt -fast; equiv_make rv_csr_file_reference rv_csr_file csr_equiv; hierarchy -top csr_equiv; opt_clean; equiv_simple -undef; equiv_status -assert"
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $command *> "$run/$name.log"
    $code=$LASTEXITCODE
    $log=Get-Content "$run/$name.log" -Raw
    $passed=if($negative){$code -ne 0 -and $log -match 'unproven \$equiv'}else{$code -eq 0 -and $log -match 'Equivalence successfully proven!'}
    $report.cases+=@{name=$name;passed=$passed;negative=$negative;exitCode=$code}
    $report | ConvertTo-Json -Depth 5 | Set-Content "$run/report.json"
    if(!$passed){throw "Failed/incomplete CSR equivalence $name"}
    Write-Output "PASS CSR $name"
  }
  $report.passed=$true;$report | ConvertTo-Json -Depth 5 | Set-Content "$run/report.json"
} finally {$env:PATH=$savedPath;if($pushed){Pop-Location}; & subst "$drive`:" /d | Out-Null}
