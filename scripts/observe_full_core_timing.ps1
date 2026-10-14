param(
  [Parameter(Mandatory=$true)][string]$BuildRoot,
  [ValidatePattern('^Abc\.observer(?:_v[0-9]+)?$')][string]$EvidencePrefix='Abc.observer',
  [ValidateRange(1,128)][double]$MaxYosysPrivateGiB=10,
  [ValidateRange(0.25,64)][double]$MinAvailableCommitGiB=1.5,
  # Read-only recovery after the launcher already failed to stop its child.
  # This neither starts/restarts synthesis nor passes/lowers any memory guard.
  # Retain a native handle so an eventual exit is not lost during low memory.
  [switch]$CaptureExitOnly
)
# Attach to the SAME live native process after its launcher failed. Never
# restart it, invent an exit code, or overwrite the original guard evidence.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path -Parent $PSScriptRoot
$run=(Resolve-Path -LiteralPath $BuildRoot).Path
if (!$run.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'BuildRoot must be below workspace'}
$record=Get-Content "$run/Abc.active.json" -Raw | ConvertFrom-Json
$manifest=Get-Content "$run/run_manifest.json" -Raw | ConvertFrom-Json
$stageHistory=Get-Content "$run/Abc.result.json" -Raw | ConvertFrom-Json
$targetPs=[int]$stageHistory.targetDelayPs
# Older manifests do not store the ABC target. Bind it to the actual saved
# stage record and script instead of inventing a default or changing inputs.
$abcCommands=Get-Content "$run/Abc.ys" -Raw
if ($targetPs -le 0 -or $abcCommands -notmatch ("-D\s+"+$targetPs+'(?:\s|;)')) {throw 'Actual ABC target cannot be established'}
if ($manifest.topModule -ne 'rv_ooo_core' -or $manifest.parameters -ne '' -or
    $manifest.resetModel -ne 'retained') {throw 'Unexpected scope/configuration'}
foreach ($inputSource in $manifest.sources) {
  if ((Get-FileHash "$run/snapshot/$($inputSource.Path)").Hash -ne $inputSource.Sha256) {throw 'Frozen source mismatch'}
}
if ((Get-FileHash "$run/library.lib").Hash -ne $manifest.libertySha256 -or
    (Get-FileHash "$run/abc.constr").Hash -ne $manifest.constraintSha256) {throw 'Frozen library/constraint mismatch'}
$native=[Diagnostics.Process]::GetProcessById([int]$record.nativeProcessId)
if ($native.ProcessName -ne 'yosys' -or
    [Math]::Abs(($native.StartTime.ToUniversalTime()-([DateTime]$record.nativeStartUtc).ToUniversalTime()).TotalSeconds) -gt 3) {throw 'Live native identity mismatch'}
# Non-child .NET Process objects can report a null ExitCode after Refresh.
# Hold an explicit Windows QUERY_LIMITED_INFORMATION|SYNCHRONIZE handle.
# Never interpret a null managed property as either native success/failure.
if (!('TimingObserverMemory' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TimingObserverMemory {
  [StructLayout(LayoutKind.Sequential)] public struct Status {
    public uint length, load;
    public ulong totalPhysical, availablePhysical, totalPageFile, availablePageFile;
    public ulong totalVirtual, availableVirtual, availableExtendedVirtual;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GlobalMemoryStatusEx(ref Status value);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool CloseHandle(IntPtr handle);
}
'@
}
$attachedUtc=[DateTime]::UtcNow.ToString('o')
$peak=0.0;$lastReport=[DateTime]::MinValue;$exitCode=$null
$memorySafetyPassed=$true;$guardEvidenceRecorded=$false
if ($CaptureExitOnly -and !$stageHistory.processStillAlive) {
  throw 'Exit-only capture requires an existing launcher record of a live owned child'
}
$kernelHandle=[TimingObserverMemory]::OpenProcess(0x101000,$false,[uint32]$native.Id)
if ($kernelHandle -eq [IntPtr]::Zero) {throw 'Cannot acquire native query/synchronization handle'}
try {
  $initialCode=[uint32]0
  if (![TimingObserverMemory]::GetExitCodeProcess($kernelHandle,[ref]$initialCode) -or $initialCode -ne 259) {throw 'Native not live at handle capture'}
  while ($true) {
    $waitStatus=[TimingObserverMemory]::WaitForSingleObject($kernelHandle,2000)
    if ($waitStatus -eq 0) {break}
    if ($waitStatus -ne 258) {throw 'Native synchronization wait failed'}
    $native.Refresh()
    $memory=[TimingObserverMemory+Status]::new()
    $memory.length=[Runtime.InteropServices.Marshal]::SizeOf($memory)
    if (![TimingObserverMemory]::GlobalMemoryStatusEx([ref]$memory)) {throw 'Memory query failed'}
    $privateGiB=$native.PrivateMemorySize64/1GB
    $availableGiB=$memory.availablePageFile/1GB
    $peak=[Math]::Max($peak,$privateGiB)
    $elapsed=([DateTime]::UtcNow-([DateTime]$record.nativeStartUtc).ToUniversalTime()).TotalSeconds
    if ($privateGiB -gt $MaxYosysPrivateGiB -or $availableGiB -lt $MinAvailableCommitGiB) {
      $memorySafetyPassed=$false
      if (!$CaptureExitOnly) {
        throw "Safety limit crossed again; native PID=$($native.Id) still owned/live. Inspect resources before further observation."
      }
      if (!$guardEvidenceRecorded) {
        @{nativeProcessId=$native.Id;nativeStartUtc=$record.nativeStartUtc;
          recordedUtc=[DateTime]::UtcNow.ToString('o');privateGiB=$privateGiB;
          availableCommitGiB=$availableGiB;maxYosysPrivateGiB=$MaxYosysPrivateGiB;
          minAvailableCommitGiB=$MinAvailableCommitGiB;memorySafetyPassed=$false;
          scope='Read-only exit capture after launcher stop failure; NOT a guard pass or new synthesis'} |
          ConvertTo-Json | Set-Content "$run/$EvidencePrefix.guard.json"
        Write-Warning 'Memory guard remains FAILED; exit-only observer does not start/restart synthesis or alter the safety thresholds'
        $guardEvidenceRecorded=$true
      }
    }
    if (([DateTime]::UtcNow-$lastReport).TotalSeconds -ge 45) {
      @{status='observing_same_live_native';nativeProcessId=$native.Id;nativeStartUtc=$record.nativeStartUtc;
        observerProcessId=$PID;attachedUtc=$attachedUtc;heartbeatUtc=[DateTime]::UtcNow.ToString('o');
        manifestSha256=(Get-FileHash "$run/run_manifest.json").Hash;
        seconds=$elapsed;privateGiB=$privateGiB;availableCommitGiB=$availableGiB;
        captureExitOnly=[bool]$CaptureExitOnly;memorySafetyPassed=$memorySafetyPassed;
        scope='Same live native/held synchronization handle; NOT successful completion'} |
        ConvertTo-Json -Depth 4 | Set-Content "$run/$EvidencePrefix.active.json"
      Write-Output "OBSERVE same native PID=$($native.Id) $([Math]::Round($elapsed))s private=$([Math]::Round($privateGiB,2))GiB available=$([Math]::Round($availableGiB,2))GiB"
      $lastReport=[DateTime]::UtcNow
    }
  }
  $nativeCode=[uint32]0
  if (![TimingObserverMemory]::GetExitCodeProcess($kernelHandle,[ref]$nativeCode)) {throw 'Native exit code query failed; completion unproven'}
  $exitCode=[int64]$nativeCode
  @{nativeProcessId=$native.Id;nativeStartUtc=$record.nativeStartUtc;attachedUtc=$attachedUtc;
    completedUtc=[DateTime]::UtcNow.ToString('o');exitCode=$exitCode;processStillAlive=$false;
    peakObservedPrivateGiB=$peak;originalGuardEvidencePreserved=$true;
    captureExitOnly=[bool]$CaptureExitOnly;memorySafetyPassed=$memorySafetyPassed;
    scope='Actual native exit code from the held process handle; no re-execution'} |
    ConvertTo-Json -Depth 4 | Set-Content "$run/$EvidencePrefix.result.json"
  if ($exitCode -ne 0) {throw "Native failed with actual exit=$exitCode"}
  foreach ($stage in @('Coarse','Map','Fine','Flatten')) {
    if ((Get-Content "$run/$stage.result.json" -Raw | ConvertFrom-Json).exitCode -ne 0) {throw 'Earlier native stage not successful'}
  }
  $log=Get-Content "$run/Abc.log" -Raw
  $delays=[regex]::Matches($log,'Delay\s*=\s*([0-9.]+)\s*ps')
  $areas=[regex]::Matches($log,"Chip area for module '[^']+':\s*([0-9.]+)")
  if (!$delays.Count -or !$areas.Count -or !(Test-Path "$run/mapped.v")) {throw 'Native output incomplete'}
  @{delayPs=[double]$delays[$delays.Count-1].Groups[1].Value;
    mappedAreaUm2=[double]$areas[$areas.Count-1].Groups[1].Value;
    targetDelayPs=$targetPs;memoryModel='all arrays mapped; reset retained';
    parameters=$manifest.parameters;scope=$manifest.scope;coreDefaults=$manifest.coreDefaults;
    sourceRoot=$manifest.sourceRoot;sources=$manifest.sources;libertySha256=$manifest.libertySha256;
    constraintSha256=$manifest.constraintSha256;yosysSha256=$manifest.yosysSha256;
    abcSha256=$manifest.abcSha256;actualExitCode=$exitCode;
    originalLauncherMemorySafetyPassed=($null -eq $stageHistory.failure);
    observerMemorySafetyPassed=$memorySafetyPassed;captureExitOnly=[bool]$CaptureExitOnly;
    completionEvidence="$EvidencePrefix.result.json; original launcher guard/result evidence retained"} |
    ConvertTo-Json -Depth 8 | Set-Content "$run/timing_summary.json"
  Write-Output 'PASS same native completed normally; timing summary harvested without re-execution'
} finally {$null=[TimingObserverMemory]::CloseHandle($kernelHandle);$native.Dispose()}
