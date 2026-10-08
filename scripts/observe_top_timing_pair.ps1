param(
  [string]$BaselineRun='out/top_scope_agu_mask_full',
  [string]$CandidateRun='out/top_scope_counter_current_full',
  [string]$QueueRecord='out/top_scope_v14_queue.json',
  [string]$Output='out/top_scope_v14_whole_comparison.json',
  [ValidateRange(1,1440)][int]$TimeoutMinutes=240
)
# Observe existing native full-core jobs only. No synthesis invocation,
# hardware overrides, process termination, or RTL mutation is performed.
# Nangate45 screening cannot establish private-process Fmax.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function WorkspacePath([string]$path){
  $full=[IO.Path]::GetFullPath((Join-Path $repo $path))
  if(!$full.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'All paths must stay below workspace'}
  return $full
}
$baseline=WorkspacePath $BaselineRun
$candidate=WorkspacePath $CandidateRun
$queue=WorkspacePath $QueueRecord
$destination=WorkspacePath $Output
if(Test-Path -LiteralPath $destination){throw 'Refusing to overwrite comparison evidence'}
$deadline=[DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$lastStatus=''
while($true){
  if([DateTime]::UtcNow -gt $deadline){throw 'Native jobs have not completed within observer window; not a timing PASS'}
  $state=Get-Content -LiteralPath $queue -Raw | ConvertFrom-Json
  if($state.status -ne $lastStatus){Write-Output "Observe existing queue: $($state.status)";$lastStatus=$state.status}
  if($state.status -eq 'complete'){break}
  if($state.status -eq 'failed' -or $state.status -eq 'superseded'){throw "Queue ended without latest timing: $($state.status)"}
  Start-Sleep -Seconds 20
}
$a=Get-Content -LiteralPath (Join-Path $baseline 'timing_summary.json') -Raw | ConvertFrom-Json
$b=Get-Content -LiteralPath (Join-Path $candidate 'timing_summary.json') -Raw | ConvertFrom-Json
$am=Get-Content -LiteralPath (Join-Path $baseline 'run_manifest.json') -Raw | ConvertFrom-Json
$bm=Get-Content -LiteralPath (Join-Path $candidate 'run_manifest.json') -Raw | ConvertFrom-Json
foreach($run in @($baseline,$candidate)){
  foreach($stage in @('Coarse','Map','Fine','Flatten','Abc')){
    $native=Get-Content -LiteralPath (Join-Path $run "$stage.result.json") -Raw | ConvertFrom-Json
    if($native.exitCode -ne 0 -or $native.failure -or $native.processStillAlive){throw "Native stage not complete: $run/$stage"}
  }
}
foreach($manifest in @($am,$bm)){
  if($manifest.topModule -ne 'rv_ooo_core' -or $manifest.parameters -ne '' -or $manifest.resetModel -ne 'retained' -or $manifest.sources.Count -ne 31){throw 'Full-core configuration/model mismatch'}
}
foreach($property in @('libertySha256','constraintSha256','yosysSha256','abcSha256','targetDelayPs','memoryModel')){
  if($a.$property -ne $b.$property){throw "Unmatched screening condition: $property"}
}
foreach($property in $am.coreDefaults.PSObject.Properties){
  if($bm.coreDefaults.($property.Name) -ne $property.Value){throw "Hardware configuration mismatch: $($property.Name)"}
}
$changed=@()
foreach($source in $bm.sources){
  $original=@($am.sources | Where-Object Path -eq $source.Path)
  if($original.Count -ne 1){throw 'Unmatched source list'}
  if($original[0].Sha256 -ne $source.Sha256){$changed+=$source.Path}
  if((Get-FileHash -LiteralPath (Join-Path (Join-Path $candidate 'snapshot') $source.Path)).Hash -ne $source.Sha256){throw 'Frozen candidate hash differs'}
}
if($changed.Count -ne 1 -or $changed[0] -ne 'rtl/backend/rv_csr_file.sv'){throw 'This matched counter comparison expects only CSR source to differ'}
$productionMatches=@($bm.sources | Where-Object {(Get-FileHash -LiteralPath (Join-Path $repo $_.Path)).Hash -ne $_.Sha256}).Count -eq 0
$report=@{
  scope='Actual full-array reset-retained rv_ooo_core, identical Nangate45 conditions; NOT private2nm STA/Fmax'
  completedUtc=[DateTime]::UtcNow.ToString('o')
  baseline=$BaselineRun;candidate=$CandidateRun;changedSources=$changed
  baselineDelayPs=$a.delayPs;candidateDelayPs=$b.delayPs
  delayChangePercent=100*($b.delayPs/$a.delayPs-1)
  baselineAreaUm2=$a.mappedAreaUm2;candidateAreaUm2=$b.mappedAreaUm2
  areaChangePercent=100*($b.mappedAreaUm2/$a.mappedAreaUm2-1)
  productionStillMatchesCandidate=$productionMatches
  nativeStages='All five stages of both runs have actual exit0'
  coreDefaults=$bm.coreDefaults;parameters=$bm.parameters
  timingSummaries=@(@{path="$BaselineRun/timing_summary.json";sha256=(Get-FileHash (Join-Path $baseline 'timing_summary.json')).Hash},
    @{path="$CandidateRun/timing_summary.json";sha256=(Get-FileHash (Join-Path $candidate 'timing_summary.json')).Hash})
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $destination -Encoding UTF8
Write-Output "Completed native Top comparison: $($a.delayPs) -> $($b.delayPs) ps; change=$($report.delayChangePercent)% (N45 only)"
