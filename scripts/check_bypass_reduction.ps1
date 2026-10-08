param(
  [string]$SourceRoot='',
  [string]$Baseline='8e2e255',
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite',
  [string]$BuildRoot=''
)
# Exact production function extraction. Proves all inputs under the existing
# at-most-one producer-hit contract. NOT proof of whole-core tag uniqueness.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repo}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/bypass_reduction_formal'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be below workspace'}
$reference=(& git -C $repo show "${Baseline}:rtl/backend/rv_backend.sv") -join "`n"
if($LASTEXITCODE){throw 'Missing immutable backend reference'}
$candidate=Get-Content "$SourceRoot/rtl/backend/rv_backend.sv" -Raw
$pattern='(?s)function automatic logic \[XLEN-1:0\] bypass_or_prf\(.*?endfunction'
$old=[regex]::Match($reference,$pattern);$new=[regex]::Match($candidate,$pattern)
if(!$old.Success -or !$new.Success){throw 'Production bypass function missing'}
$oldFunction=$old.Value.Replace('bypass_or_prf','reference_bypass').Replace('DIRECT_SOURCE_PORTS','DIRECT_BYPASS_PORTS')
$newFunction=$new.Value.Replace('bypass_or_prf','candidate_bypass').Replace('DIRECT_SOURCE_PORTS','DIRECT_BYPASS_PORTS')
$template=Get-Content "$repo/tb/formal/rv_bypass_reduce_template.sv" -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$oldPath=$env:PATH;$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$oldPath
  @{backendSha256=(Get-FileHash "$SourceRoot/rtl/backend/rv_backend.sv").Hash;
    baseline=(& git rev-parse $Baseline);
    scope='All combinational two-state inputs with <=1 qualifying producer hit; XLEN32/64, ports7/11; not ISA/tag-liveness proof'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($xlen in @(32,64)){foreach($ports in @(7,11)){foreach($negative in @($false,$true)){
    $name="x${xlen}_p${ports}_"+$(if($negative){'negative'}else{'positive'})
    $mask=if($negative){"^ XLEN'(1)"}else{''}
    $source=$template.Replace('@XLEN@',"$xlen").Replace('@PORTS@',"$ports").Replace('@REFERENCE_FUNCTION@',$oldFunction).Replace('@CANDIDATE_FUNCTION@',$newFunction).Replace('@ERROR_MASK@',$mask)
    [IO.File]::WriteAllText("$run/$name.sv",$source,[Text.UTF8Encoding]::new($false))
    $cmd="read_slang --std 1800-2017 --top rv_bypass_reduce_miter rtl/rv_ooo_pkg.sv $run/$name.sv; prep -top rv_bypass_reduce_miter -flatten; opt; sat -verify -set unique_matches 1 -prove mismatch 0 -show-inputs"
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
    if($negative){
      if($LASTEXITCODE -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){throw "Negative not rejected: $name"}
    }elseif($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)){throw "Proof incomplete/failed: $name"}
    Write-Output "PASS $name"
  }}}
}finally{
  $env:PATH=$oldPath
  if($pushed){Pop-Location}
  & subst "$drive`:" /d | Out-Null
}
