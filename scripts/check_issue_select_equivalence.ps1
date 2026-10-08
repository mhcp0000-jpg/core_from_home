param(
  [string]$SourceRoot='', [string]$BuildRoot='', [string]$Baseline='8e2e255',
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite'
)
# Exact module, all combinational inputs/outputs. Unit-test geometry is made
# explicit in generated SV parameter declarations, never a core tool override.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repo}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/issue_select_equivalence'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be inside workspace'}
$reference=(& git -C $repo show "${Baseline}:rtl/backend/rv_issue_arbiter.sv") -join "`n"
if($LASTEXITCODE){throw 'Missing reference'}
$candidate=Get-Content "$SourceRoot/rtl/backend/rv_issue_arbiter.sv" -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$savedPath=$env:PATH;$pushed=$false
function Unit-Source([string]$text,[string]$name,[int]$candidates,[int]$ports,[int]$ordered){
  $text=$text.Replace('module rv_issue_arbiter #(',"module $name #(")
  foreach($replacement in @(
    @('CANDIDATE_COUNT = 5',"CANDIDATE_COUNT = $candidates"),
    @('EXEC_PORTS = 5',"EXEC_PORTS = $ports"),
    @("AGE_ORDERED = 1'b0","AGE_ORDERED = 1'b$ordered"))) {
    if(!$text.Contains($replacement[0])){throw 'Unexpected module default declaration'}
    $text=$text.Replace($replacement[0],$replacement[1])
  }
  return $text
}
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$savedPath
  @{baseline=(& git rev-parse $Baseline);arbiterSha256=(Get-FileHash "$SourceRoot/rtl/backend/rv_issue_arbiter.sv").Hash;
    scope='All combinational outputs; actual C2/P5/AGE1 + unit geometries, no whole-core proof'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  $cases=@(@(2,5,1),@(2,3,1),@(2,7,1),@(2,5,0),@(5,5,0))
  foreach($cfg in $cases){
    foreach($negative in @($false,$true)){
      if($negative -and ($cfg -join '_') -ne '2_5_1'){continue}
      $name=($cfg -join '_')+$(if($negative){'_negative'}else{'_positive'})
      $gold=Unit-Source $reference 'gold' @cfg
      $gate=Unit-Source $candidate 'gate' @cfg
      if($negative){
        $point='fgrant2 = candidate_valid_i[0] && (|fpair);'
        if(!$gate.Contains($point)){throw 'Expected negative-control insertion point missing'}
        $gate=$gate.Replace($point,"fgrant2 = 1'b0;")
      }
      [IO.File]::WriteAllText("$run/$name.sv",$gold+"`n"+$gate,[Text.UTF8Encoding]::new($false))
      $cmd="read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial rtl/rv_ooo_pkg.sv $run/$name.sv; miter -equiv -flatten gold gate miter; prep -top miter; opt; sat -verify -prove trigger 0 -show-inputs"
      & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
      $code=$LASTEXITCODE
      if($negative){
        if($code -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){throw 'Negative control not rejected'}
      } elseif($code -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)){throw "Unproven $name"}
      Write-Output "PASS $name"
    }
  }
} finally {
  if($pushed){Pop-Location}
  $env:PATH=$savedPath
  & subst "$drive`:" /d | Out-Null
}
