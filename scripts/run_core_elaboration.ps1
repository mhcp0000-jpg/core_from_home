param(
  [string]$SourceRoot='',
  [string]$BuildRoot='',
  [string]$VerilatorRoot='C:/rv_toolchains/verilator-5.050'
)
# Structural elaboration of the actual core defaults plus explicit SV smoke
# instances for XLEN32/64 x branch/div pipeline modes. No -G hardware overrides.
# This does NOT execute an RV64 program or sign off ISA/timing functionality.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repo}
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/core_elaboration'}
$build=[IO.Path]::GetFullPath($BuildRoot)
foreach($path in @($source,$build)){
  if($path -ne $repo -and !$path.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw 'Source and output must stay inside workspace'
  }
}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII workspace alias'}
$savedRoot=$env:VERILATOR_ROOT
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $sourceAlias="$drive`:/"+$source.Substring($repo.Length).TrimStart('\').Replace('\','/')
  $buildAlias="$drive`:/"+$build.Substring($repo.Length).TrimStart('\').Replace('\','/')
  New-Item -ItemType Directory -Force -Path $buildAlias | Out-Null
  $cfg=& "$PSScriptRoot/read_core_config.ps1" -PackagePath "$source/rtl/rv_ooo_pkg.sv"
  $files=Get-Content "$repo/sim/xcelium/sources_core.f" | Where-Object {
    $_.Trim() -and !$_.Trim().StartsWith('#') -and !$_.Trim().StartsWith('//')
  }
  $sources=@($files | ForEach-Object {"$sourceAlias/$($_.Trim())"})
  $identities=@($files | ForEach-Object {
    @{Path=$_.Trim();Sha256=(Get-FileHash "$source/$($_.Trim())").Hash}
  })
  $env:VERILATOR_ROOT=$VerilatorRoot
  foreach($top in @('rv_ooo_core','rv_tag_pipeline_smoke')) {
    $inputs=$sources
    if($top -ne 'rv_ooo_core'){$inputs+= "$drive`:/tb/elaboration/rv_ooo_elab_smoke.sv"}
    & "$VerilatorRoot/bin/verilator_bin.exe" --lint-only --timing --assert -Wno-fatal -Werror-UNOPTFLAT `
      --top-module $top --Mdir "$buildAlias/$top" @inputs *> "$buildAlias/$top.log"
    if($LASTEXITCODE){throw "Elaboration failed: $top (see $BuildRoot/$top.log)"}
    Write-Output "PASS $top elaboration (not execution)"
  }
  @{sources=$identities;coreDefaults=$cfg;configurationMode='RTL defaults; smoke combinations explicit in SV';
    scope='Core default + XLEN32/64 x branch/div structural elaboration only';actualExitCode=0} |
    ConvertTo-Json -Depth 6 | Set-Content "$buildAlias/run_manifest.json" -Encoding UTF8
} finally {
  $env:VERILATOR_ROOT=$savedRoot
  & subst "$drive`:" /d | Out-Null
}
