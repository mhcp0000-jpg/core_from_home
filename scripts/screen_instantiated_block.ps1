param(
  [Parameter(Mandatory=$true)][string]$FullRun,
  [Parameter(Mandatory=$true)][string]$BuildRoot,
  [string]$Module='rv_exec_result_buffer$rv_ooo_core.u_backend.g_fast[0].u_buffer',
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite',
  [int]$TargetDelayPs=1000
)
# Extract an already-elaborated instance from the REAL rv_ooo_core snapshot.
# Never re-elaborate a standalone module with different leaf default geometry.
# Block-boundary ABC is screening only; not whole-core timing or private STA.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$full=(Resolve-Path $FullRun).Path
$build=[IO.Path]::GetFullPath($BuildRoot)
foreach($path in @($full,$build)){
  if(!$path.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Inputs/output must be below repository'}
}
$manifest=Get-Content "$full/run_manifest.json" -Raw | ConvertFrom-Json
if($manifest.topModule -ne 'rv_ooo_core' -or $manifest.parameters -ne ''){
  throw 'Expected actual core elaboration with RTL defaults and no tool overrides'
}
if((Get-Content "$full/Map.result.json" -Raw | ConvertFrom-Json).exitCode -ne 0){throw 'No successful Map checkpoint'}
foreach($source in $manifest.sources){
  if((Get-FileHash "$full/snapshot/$($source.Path)").Hash -ne $source.Sha256){throw 'Frozen source changed'}
}
if($Module -notmatch '^[A-Za-z0-9_.$\[\]]+$'){throw 'Invalid module identifier'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive alias'}
$savedPath=$env:PATH;$savedTemp=$env:TEMP;$savedTmp=$env:TMP;$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  $input="$drive`:/"+$full.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path "$run/tmp" | Out-Null
  $env:TEMP="$run/tmp";$env:TMP="$run/tmp"
  Copy-Item "$input/library.lib","$input/abc.constr" -Destination $run
  @('strash','&get -n','&dch -f',"&nf -D $TargetDelayPs",'&put','buffer',"upsize -D $TargetDelayPs","dnsize -D $TargetDelayPs",'stime -p') |
    Set-Content "$run/abc.scr" -Encoding ASCII
  @{
    fullRun=$full; instantiatedModule=$Module; actualCoreDefaults=$manifest.coreDefaults
    sources=$manifest.sources; checkpointSha256=(Get-FileHash "$input/mapped_arrays.il").Hash
    libertySha256=(Get-FileHash "$run/library.lib").Hash
    scope='Actual core instance geometry, block-boundary Nangate45 screening; NOT whole-core timing or 2nm STA'
  } | ConvertTo-Json -Depth 6 | Set-Content "$run/manifest.json" -Encoding UTF8
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$savedPath
  $cmd="read_rtlil $input/mapped_arrays.il; hierarchy -check -top $Module; rename $Module block_under_test; flatten; techmap; opt; dfflibmap -liberty $run/library.lib; " +
    "select -assert-none t:`$mem*; write_rtlil $run/pre_abc.il; abc -exe $ToolRoot/bin/yosys-abc.exe -script $run/abc.scr -liberty $run/library.lib -constr $run/abc.constr -D $TargetDelayPs; clean; read_liberty -lib $run/library.lib; check; stat -liberty $run/library.lib"
  & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/synthesis.log"
  if($LASTEXITCODE){throw "Instance screen failed: $run/synthesis.log"}
  $log=Get-Content "$run/synthesis.log" -Raw
  $delays=[regex]::Matches($log,'Delay\s*=\s*([0-9.]+)\s*ps')
  $areas=[regex]::Matches($log,"Chip area for module '[^']+':\s*([0-9.]+)")
  if(!$delays.Count -or !$areas.Count){throw 'Missing actual completed timing/area report'}
  @{
    delayPs=[double]$delays[$delays.Count-1].Groups[1].Value
    areaUm2=[double]$areas[$areas.Count-1].Groups[1].Value
    instantiatedModule=$Module; configurationMode='Existing core snapshot; no re-elaboration or hardware tool overrides'
    scope='Block-boundary Nangate45 screening only'
  } | ConvertTo-Json | Set-Content "$run/timing_summary.json" -Encoding UTF8
  Get-Content "$run/timing_summary.json"
} finally {
  $env:PATH=$savedPath
  $env:TEMP=$savedTemp;$env:TMP=$savedTmp
  if($pushed){Pop-Location}
  & subst "$drive`:" /d | Out-Null
}
