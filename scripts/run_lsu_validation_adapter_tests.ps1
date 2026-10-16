param(
  [string]$SourceRoot='',
  [string]$BuildRoot='',
  [string]$Python='C:/rv_toolchains/oss-cad-suite/lib/python3.exe',
  [string]$Verilator='C:/rv_toolchains/verilator-5.050/bin/verilator_bin.exe',
  [string]$Make='C:/rv_toolchains/w64devkit-2.9.1/w64devkit/bin/make.exe',
  [ValidateRange(1,32)][int]$BuildJobs=1
)
# Actual extracted adapter + real FIFO/WB, not a replacement behavioral model.
# This fixture sets only its own unit geometry; no core hardware overrides.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path.TrimEnd('\')
if(!$SourceRoot){$SourceRoot=$repo}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/lsu_validation_adapter_tests'}
$source=(Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$build=[IO.Path]::GetFullPath($BuildRoot)
if($source -ne $repo -and !$source.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'SourceRoot must be inside this repository'
}
if(!$build.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'BuildRoot must be below this repository'
}
if(Test-Path -LiteralPath $build){throw 'Choose a new BuildRoot; never overwrite prior observations'}
foreach($tool in @($Python,$Verilator,$Make)){
  if(!(Test-Path -LiteralPath $tool)){throw "Missing executable: $tool"}
}
$drive=@('M','N','P','Q','R','S','T','U','V','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive alias'}
$ownedAlias=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $ownedAlias=$true
  $alias="$drive`:/"
  $sourceAlias=if($source -eq $repo){$alias}else{$alias+$source.Substring($repo.Length+1).Replace('\','/')}
  $buildAlias=$alias+$build.Substring($repo.Length+1).Replace('\','/')
  & $Python ($alias+'scripts/check_lsu_validation_adapter.py') --source-root $sourceAlias `
    --out $buildAlias --verilator $Verilator --make $Make --jobs $BuildJobs
  if($LASTEXITCODE){throw 'Actual LSU validation adapter regression failed; inspect report/logs'}
} finally {
  if($ownedAlias){& subst "$drive`:" /d | Out-Null}
}
