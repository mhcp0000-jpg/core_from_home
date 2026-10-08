param([Parameter(Mandatory=$true)][string]$BuildRoot,[Parameter(Mandatory=$true)][int]$ProcessId,
      [ValidateSet('Fine','Abc')][string]$Stage='Abc')
# Recover observation of an ALREADY RUNNING owned Yosys after a runner guard
# failed to terminate it. Never launch/kill a process or overwrite the failed
# stage record. Native process handle, frozen identities and actual exit are
# required before reporting a completed mapping. Not physical/2nm STA.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$build=(Resolve-Path -LiteralPath $BuildRoot).Path
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Build must be below workspace'}
$stageRecord=Get-Content "$build/$Stage.result.json" -Raw | ConvertFrom-Json
$manifest=Get-Content "$build/run_manifest.json" -Raw | ConvertFrom-Json
if($stageRecord.processId -ne $ProcessId -or !$stageRecord.processStillAlive -or $stageRecord.exitCode -ne $null){throw 'Not the outstanding owned native process'}
if($manifest.topModule -ne 'rv_ooo_core' -or $manifest.parameters -ne ''){throw 'Not the unmodified actual-top configuration'}
foreach($source in $manifest.sources){
  if((Get-FileHash "$build/snapshot/$($source.Path)").Hash -ne $source.Sha256){throw 'Frozen source mismatch'}
}
$process=Get-Process -Id $ProcessId
if($process.ProcessName -ne 'yosys' -or (Get-FileHash $process.Path).Hash -ne $manifest.yosysSha256){throw 'PID is not the frozen Yosys executable'}
$nativeHandle=$process.Handle # Retain before process exits; no synthetic exit0.
$startUtc=$process.StartTime.ToUniversalTime().ToString('o')
if($process.StartTime.ToUniversalTime() -gt (Get-Item "$build/$Stage.result.json").LastWriteTimeUtc){throw 'PID was reused after the owned guard record'}
@{processId=$ProcessId;nativeStartUtc=$startUtc;status='observing';priorGuardRecordPreserved=$true;
  observationStartedUtc=[DateTime]::UtcNow.ToString('o')} |
  ConvertTo-Json | Set-Content "$build/$Stage.observation.json" -Encoding UTF8
Write-Output "OBSERVE owned Yosys PID=$ProcessId start=$startUtc (no launch/kill)"
while(!$process.WaitForExit(2000)) {$process.Refresh()}
$process.WaitForExit();$process.Refresh()
$exitCode=$process.ExitCode
$log=Get-Content "$build/$Stage.log" -Raw
if($Stage -eq 'Fine'){
  $checkpoint="$build/fine_hierarchy.il"
  $success=($exitCode -eq 0 -and (Test-Path $checkpoint))
  @{stage=$Stage;processId=$ProcessId;nativeStartUtc=$startUtc;actualNativeExitCode=$exitCode;
    completedSuccessfully=$success;checkpointSha256=$(if($success){(Get-FileHash $checkpoint).Hash}else{$null});
    priorGuardRecordPreserved=$true;completedUtc=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content "$build/$Stage.observed.result.json" -Encoding UTF8
  if(!$success){throw 'Owned Fine process exited without a complete checkpoint'}
  Write-Output 'PASS observed actual native Fine exit0; prior guard failure preserved'
  exit
}
$delay=[regex]::Matches($log,'Delay\s*=\s*([0-9.]+)\s*ps')
$area=[regex]::Matches($log,"Chip area for module '[^']+':\s*([0-9.]+)")
$success=($exitCode -eq 0 -and $delay.Count -gt 0 -and $area.Count -gt 0 -and (Test-Path "$build/mapped.v"))
@{processId=$ProcessId;nativeStartUtc=$startUtc;actualNativeExitCode=$exitCode;completedUtc=[DateTime]::UtcNow.ToString('o');
  completedSuccessfully=$success;priorGuardRecordPreserved=$true;
  scope='Whole actual rv_ooo_core, all FF/reset, Nangate45 ABC screening; NOT 2nm STA'} |
  ConvertTo-Json | Set-Content "$build/Abc.observed.result.json" -Encoding UTF8
if(!$success){throw 'Owned ABC terminated without complete successful output; do not call it a timing result'}
@{delayPs=[double]$delay[$delay.Count-1].Groups[1].Value;areaUm2=[double]$area[$area.Count-1].Groups[1].Value;
  configurationMode=$manifest.configurationMode;coreDefaults=$manifest.coreDefaults;
  preAbcSha256=(Get-FileHash "$build/pre_abc.il").Hash;mappedSha256=(Get-FileHash "$build/mapped.v").Hash;
  actualNativeExitCode=$exitCode;scope='Actual whole-core Nangate45 screening; NOT private 2nm physical STA'} |
  ConvertTo-Json -Depth 5 | Set-Content "$build/timing_observed_summary.json" -Encoding UTF8
Get-Content "$build/timing_observed_summary.json"
