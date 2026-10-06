param(
  [string]$ToolRoot = "C:\rv_toolchains\oss-cad-suite",
  [string]$Liberty = "C:\rv_toolchains\libs\nangate45\NangateOpenCellLibrary_typical.lib",
  [string]$BuildRoot = "",
  [ValidateSet("rv_ooo_core", "rv_issue_queue", "rv_rob", "rv_writeback_arbiter", "rv_exec_result_buffer", "rv_lsq", "rv_csr_file", "rv_lsu_cluster")]
  [string]$TopModule = "rv_ooo_core",
  # Optional immutable source snapshot for a matched A/B leaf run.
  # Input identities are still hashed; gitCommit alone is not source identity.
  [string]$SourceRoot = "",
  [ValidateSet("DirectFlops", "Inferred")]
  [string]$ArrayLowering = "DirectFlops",
  [ValidateSet("Coarse", "Map", "Fine", "Flatten", "Abc")]
  [string]$StartStage = "Coarse",
  [ValidateSet("Coarse", "Map", "Fine", "Flatten", "Abc")]
  [string]$StopStage = "Abc",
  [ValidateRange(100, 1000000)][int]$TargetDelayPs = 1000,
  [ValidateRange(1, 128)][double]$MaxYosysPrivateGiB = 10,
  [ValidateRange(0.25, 64)][double]$MinAvailableCommitGiB = 1.5
)
# Faithful full-array top screening. Reset is NEVER tied off. Array reads are
# NEVER left as black-box memory boundaries. Not physical STA or a 2nm estimate.
# Hierarchical mapping and process checkpoints bound transient memory use.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
if (!$SourceRoot) { $SourceRoot = $repoRoot }
$sourceFull = (Resolve-Path -LiteralPath $SourceRoot).Path
$coreConfig = if ($TopModule -eq 'rv_ooo_core' -and $StartStage -eq 'Coarse') {
  & (Join-Path $PSScriptRoot 'read_core_config.ps1') -PackagePath (Join-Path $sourceFull 'rtl/rv_ooo_pkg.sv')
} else { $null }
# Every top, including standalone leaves, uses its RTL defaults. A leaf's own
# default geometry is not necessarily the geometry of its core instance.
# A checkpoint resume does not re-elaborate or change its historical config.
$parameterArgs = ''
if (!$BuildRoot) { $BuildRoot = Join-Path $repoRoot "out/full_core_timing" }
if ($StartStage -eq 'Coarse') {
  Write-Host "ELABORATION_CONFIG top=$TopModule source=$sourceFull (RTL defaults only; no tool overrides)"
  if ($coreConfig) { Write-Host "CORE_CONFIG $($coreConfig | ConvertTo-Json -Compress)" }
} else {
  Write-Host "CHECKPOINT_RESUME top=$TopModule stage=$StartStage (frozen inputs; no re-elaboration)"
}
$buildFull = [IO.Path]::GetFullPath($BuildRoot)
$yosys = Join-Path $ToolRoot "bin/yosys.exe"
$abc = Join-Path $ToolRoot "bin/yosys-abc.exe"
foreach ($path in @($yosys, $abc, $Liberty)) {
  if (!(Test-Path -LiteralPath $path)) { throw "Missing input: $path" }
}
if (!("FullCoreMemoryStatus" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FullCoreMemoryStatus {
  [StructLayout(LayoutKind.Sequential)] public struct Status {
    public uint length, load;
    public ulong totalPhysical, availablePhysical, totalPageFile, availablePageFile;
    public ulong totalVirtual, availableVirtual, availableExtendedVirtual;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GlobalMemoryStatusEx(ref Status s);
}
'@
}
function Get-MemoryStatus {
  $s = [FullCoreMemoryStatus+Status]::new()
  $s.length = [Runtime.InteropServices.Marshal]::SizeOf($s)
  if (![FullCoreMemoryStatus]::GlobalMemoryStatusEx([ref]$s)) {
    throw "GlobalMemoryStatusEx failed"
  }
  return $s
}
function Yosys-Path([string]$path) { return $path.Replace("\", "/") }
$drive = @("Z", "Y", "X", "W", "U", "T", "S", "R") |
  Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1
if (!$drive) { throw "No unused ASCII drive alias" }
$savedPath = $env:PATH
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$pushed = $false
$ownedProcessStillAlive = $false
$stages = @("Coarse", "Map", "Fine", "Flatten", "Abc")
if ($stages.IndexOf($StartStage) -gt $stages.IndexOf($StopStage)) {
  throw "StartStage must precede StopStage"
}
try {
  & subst "$drive`:" $repoRoot
  if ($LASTEXITCODE) { throw "subst failed" }
  Push-Location "$drive`:/"
  $pushed = $true
  $repoFull = [IO.Path]::GetFullPath($repoRoot).TrimEnd("\")
  if (!$buildFull.StartsWith($repoFull + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "BuildRoot must be inside the repository (ASCII alias required)"
  }
  $run = "$drive`:/" + $buildFull.Substring($repoFull.Length + 1).Replace("\", "/")
  New-Item -ItemType Directory -Force -Path "$run/tmp" | Out-Null
  $env:TEMP = "$run/tmp"
  $env:TMP = "$run/tmp"
  $env:PATH = (Join-Path $ToolRoot "bin") + ";" + (Join-Path $ToolRoot "lib") + ";" + $savedPath
  $manifestPath = "$run/run_manifest.json"
  if ($StartStage -eq "Coarse") {
    if (Test-Path -LiteralPath $manifestPath) {
      throw "Existing run: resume with StartStage or choose a fresh BuildRoot"
    }
    $identities = @()
    $inputs = @(Get-Content sim/xcelium/sources_core.f | Where-Object {
      $_.Trim() -and !$_.Trim().StartsWith("#") -and !$_.Trim().StartsWith("//")
    })
    foreach ($inputName in $inputs) {
      $inputName = $inputName.Trim()
      $destination = "$run/snapshot/$inputName"
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
      Copy-Item -LiteralPath (Join-Path $sourceFull $inputName) -Destination $destination
      $identities += @{ Path = $inputName; Sha256 = (Get-FileHash $destination).Hash }
    }
    $inputs | Set-Content "$run/snapshot/sources.f" -Encoding ASCII
    Copy-Item -LiteralPath $Liberty -Destination "$run/library.lib"
    Copy-Item synth/open_source/nangate45_abc.constr "$run/abc.constr"
    $memory = Get-MemoryStatus
    @{
      gitCommit = (& git rev-parse HEAD); startedUtc = [DateTime]::UtcNow.ToString("o")
      sources = $identities; libertySha256 = (Get-FileHash "$run/library.lib").Hash
      constraintSha256 = (Get-FileHash "$run/abc.constr").Hash
      yosysSha256 = (Get-FileHash $yosys).Hash; abcSha256 = (Get-FileHash $abc).Hash
      runnerSha256 = (Get-FileHash $PSCommandPath).Hash
      topModule = $TopModule; sourceRoot = $sourceFull
      parameters = $parameterArgs
      configurationMode = 'RTL defaults only; no tool parameter overrides'
      coreDefaults = $coreConfig
      resetModel = "retained"; arrayModel = "all mapped to flops and muxes"
      arrayLowering = $ArrayLowering
      physicalRamGiB = $memory.totalPhysical / 1GB; commitLimitGiB = $memory.totalPageFile / 1GB
      scope = "Nangate45 combinational screening; NOT 2nm physical STA"
    } | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding UTF8
  } elseif (!(Test-Path -LiteralPath $manifestPath)) { throw "No checkpoint manifest" }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($StartStage -ne 'Coarse') {
    Write-Host "FROZEN_SOURCE $($manifest.sourceRoot)"
    if ($manifest.PSObject.Properties.Name -contains 'coreDefaults') {
      Write-Host "FROZEN_CORE_CONFIG $($manifest.coreDefaults | ConvertTo-Json -Compress)"
    }
  }
  if ($manifest.PSObject.Properties.Name -contains "topModule") {
    if ($manifest.topModule -ne $TopModule) { throw "Resume top differs from frozen top" }
  } elseif ($TopModule -ne "rv_ooo_core") { throw "Legacy checkpoint is a core run, not an IQ run" }
  foreach ($source in $manifest.sources) {
    if ((Get-FileHash "$run/snapshot/$($source.Path)").Hash -ne $source.Sha256) {
      throw "Frozen input changed: $($source.Path)"
    }
  }
  if ((Get-FileHash "$run/library.lib").Hash -ne $manifest.libertySha256 -or
      (Get-FileHash "$run/abc.constr").Hash -ne $manifest.constraintSha256 -or
      (Get-FileHash $yosys).Hash -ne $manifest.yosysSha256 -or
      (Get-FileHash $abc).Hash -ne $manifest.abcSha256) { throw "Frozen tool/library identity changed" }
  if ($StartStage -ne "Coarse") { $ArrayLowering = $manifest.arrayLowering }
  $lib = "$run/library.lib"
  @("strash", "&get -n", "&dch -f", "&nf -D $TargetDelayPs", "&put",
    "buffer", "upsize -D $TargetDelayPs", "dnsize -D $TargetDelayPs", "stime -p") |
    Set-Content "$run/abc_trim.scr" -Encoding ASCII
  $commands = @{
    Coarse = "read_slang --std 1800-2017 --single-unit --best-effort-hierarchy --ignore-assertions --ignore-initial --top $TopModule $parameterArgs -f sources.f; hierarchy -check -top $TopModule; proc; opt -fast; memory -nomap; opt_clean; stat; write_rtlil $run/coarse.il"
    Map = "read_rtlil $run/coarse.il; memory_map; opt_clean; select -assert-none t:`$mem*; stat; write_rtlil $run/mapped_arrays.il"
    Fine = ""
    Flatten = "read_rtlil $run/fine_hierarchy.il; flatten; opt -fast; dfflibmap -liberty $lib; select -assert-none t:`$mem* m:*; select -assert-none t:`$* t:`$_* %d t:`$scopeinfo %d; stat; write_rtlil $run/pre_abc.il"
    Abc = "read_rtlil $run/pre_abc.il; select -assert-none t:`$mem*; abc -exe $(Yosys-Path $abc) -script $run/abc_trim.scr -liberty $lib -constr $run/abc.constr -D $TargetDelayPs; clean; read_liberty -lib $lib; check; stat -liberty $lib; write_verilog -noattr -noexpr $run/mapped.v"
  }
  if ($ArrayLowering -eq "DirectFlops") {
    # No semantic read/write don't-cares and no reset removal. Slang lowers
    # unpacked arrays directly to word registers/read muxes, avoiding the
    # thousands of reset-generated inferred-memory write ports.
    $commands.Coarse = $commands.Coarse.Replace("--best-effort-hierarchy", "--best-effort-hierarchy --no-implicit-memories")
  }
  # In PowerShell, literal Yosys $mem must not be interpolated.
  foreach ($stage in $stages[$stages.IndexOf($StartStage)..$stages.IndexOf($StopStage)]) {
    $stageIndex = $stages.IndexOf($stage)
    if ($stageIndex -gt 0) {
      $priorStage = $stages[$stageIndex-1]
      $priorPath = "$run/$priorStage.result.json"
      if (!(Test-Path -LiteralPath $priorPath) -or
          (Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json).exitCode -ne 0) {
        throw "Cannot run ${stage}: $priorStage has no successful checkpoint result"
      }
    }
    if ($stage -eq "Fine") {
      # Map and clean each module before flattening. Whole-design techmap can
      # retain >10GiB of temporary, unoptimized gates at once on this core.
      $moduleNames = @(Select-String -LiteralPath "$run/mapped_arrays.il" -Pattern '^module ' |
        ForEach-Object { $_.Line.Substring(7).TrimStart('\') })
      if (!$moduleNames.Count) { throw "No hierarchical modules in checkpoint" }
      $commands.Fine = "read_rtlil $run/mapped_arrays.il; "
      foreach ($moduleName in $moduleNames) {
        $commands.Fine += "select -module $moduleName; techmap; opt -fast; select -clear; "
      }
      # $scopeinfo is hierarchy/source-location metadata, not a logic operator.
      $commands.Fine += "select -assert-none t:`$mem* m:*; select -assert-none t:`$* t:`$_* %d t:`$scopeinfo %d; stat; write_rtlil $run/fine_hierarchy.il"
    }
    $command = $commands[$stage]
    $command | Set-Content "$run/$stage.ys" -Encoding ASCII
    $working = if ($stage -eq "Coarse") { "$run/snapshot" } else { "$drive`:/" }
    $launch = @{
      FilePath = $yosys
      ArgumentList = @("-T", "-l", "$run/$stage.log", "-s", "$run/$stage.ys")
      WorkingDirectory = $working; WindowStyle = 'Hidden'; PassThru = $true
      RedirectStandardOutput = "$run/$stage.stdout.log"
      RedirectStandardError = "$run/$stage.stderr.log"
    }
    # On PowerShell 7, explicitly propagate the tool DLL search path. A plain
    # Start-Process can otherwise retain the inherited PATH and show a native
    # missing-libstdc++ dialog (0xc0000135) instead of starting Yosys. Windows
    # PowerShell 5.1 inherits the PATH correctly and has no -Environment option.
    # This is a runtime loader setting, NEVER a hardware parameter override.
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
      $launch.Environment = @{ PATH = $env:PATH; TEMP = $env:TEMP; TMP = $env:TMP }
    }
    $process = Start-Process @launch
    # Keep the native handle open before the child can exit; otherwise Windows
    # PowerShell Start-Process can return a null ExitCode for short-lived jobs.
    $null = $process.Handle
    $samples = [Collections.Generic.List[object]]::new()
    $peakPrivate = 0L
    $peakWorking = 0L
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastReport = -60
    $failure = $null
    $stopFailure = $null
    Write-Host "START $stage PID=$($process.Id) reset retained; all arrays included"
    try {
      while (!$process.WaitForExit(2000)) {
        $process.Refresh()
        if ($process.HasExited) { break }
        $memory = Get-MemoryStatus
        $privateBytes = $process.PrivateMemorySize64
        $workingBytes = $process.WorkingSet64
        $peakPrivate = [Math]::Max($peakPrivate, $privateBytes)
        $peakWorking = [Math]::Max($peakWorking, $workingBytes)
        $samples.Add([pscustomobject]@{ Seconds = $timer.Elapsed.TotalSeconds; PrivateGiB = $privateBytes / 1GB; WorkingGiB = $workingBytes / 1GB; AvailableCommitGiB = $memory.availablePageFile / 1GB })
        if ($timer.Elapsed.TotalSeconds - $lastReport -ge 45) {
          Write-Host ("RUN {0} {1:N0}s private={2:N2}GiB available commit={3:N2}GiB" -f $stage, $timer.Elapsed.TotalSeconds, ($privateBytes / 1GB), ($memory.availablePageFile / 1GB))
          $lastReport = $timer.Elapsed.TotalSeconds
        }
        if ($privateBytes -gt $MaxYosysPrivateGiB * 1GB -or $memory.availablePageFile -lt $MinAvailableCommitGiB * 1GB) {
          $failure = "Explicit safety guard (not a tool/hardware 7GB limit): process private > ${MaxYosysPrivateGiB}GiB or system available commit < ${MinAvailableCommitGiB}GiB"
          break
        }
      }
    } finally {
      if (!$process.HasExited) {
        & taskkill /PID $process.Id /T /F | Out-Null
        if ($LASTEXITCODE -ne 0) {
          # Do not block indefinitely if the sandbox denies cross-process kill.
          $stopFailure = "Cannot stop owned Yosys PID=$($process.Id); terminate this PID with an approved command before continuing"
          $ownedProcessStillAlive = $true
        } else { $process.WaitForExit() }
      }
      $samples | Export-Csv "$run/$stage.memory.csv" -NoTypeInformation
      @{ stage = $stage; seconds = $timer.Elapsed.TotalSeconds
        exitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null })
        processId = $process.Id; processStillAlive = !$process.HasExited; stopFailure = $stopFailure
        peakYosysPrivateGiB = $peakPrivate / 1GB; peakYosysWorkingGiB = $peakWorking / 1GB
        memorySampling = "2s parent Yosys samples; child ABC indirectly guarded by total system available commit"
        maxYosysPrivateGiB = $MaxYosysPrivateGiB; minAvailableCommitGiB = $MinAvailableCommitGiB
        failure = $failure; targetDelayPs = $TargetDelayPs } |
        ConvertTo-Json | Set-Content "$run/$stage.result.json" -Encoding UTF8
    }
    if ($stopFailure) { throw $stopFailure }
    if ($failure) { throw $failure }
    if ($process.ExitCode -ne 0) { throw "$stage failed ($($process.ExitCode)); see $run/$stage.log and stderr.log" }
    Write-Host "PASS $stage peak private=$([Math]::Round($peakPrivate / 1GB, 2))GiB"
    if ($stage -eq "Abc") {
      $logText = Get-Content -LiteralPath "$run/Abc.log" -Raw
      $delays = [regex]::Matches($logText, 'Delay\s*=\s*([0-9.]+)\s*ps')
      $areas = [regex]::Matches($logText, "Chip area for module '[^']+':\s*([0-9.]+)")
      if (!$delays.Count) { throw "ABC exited successfully but no timing report was produced" }
      @{ delayPs = [double]$delays[$delays.Count-1].Groups[1].Value
        mappedAreaUm2 = $(if ($areas.Count) { [double]$areas[$areas.Count-1].Groups[1].Value } else { $null })
        targetDelayPs = $TargetDelayPs; memoryModel = "all arrays mapped; reset retained"
        parameters = $manifest.parameters; scope = $manifest.scope
        coreDefaults = $manifest.coreDefaults; sourceRoot = $manifest.sourceRoot
        sources = $manifest.sources; libertySha256 = $manifest.libertySha256
        constraintSha256 = $manifest.constraintSha256; yosysSha256 = $manifest.yosysSha256
        abcSha256 = $manifest.abcSha256; actualExitCode = $process.ExitCode } |
        ConvertTo-Json -Depth 6 | Set-Content "$run/timing_summary.json" -Encoding UTF8
    }
  }
} finally {
  if ($pushed) { Pop-Location }
  if (!$ownedProcessStillAlive) { & subst "$drive`:" /D }
  else { Write-Warning "Kept $drive`: alias for still-running owned child; stop the reported PID before removing the alias" }
  $env:PATH = $savedPath
  $env:TEMP = $savedTemp
  $env:TMP = $savedTmp
}
