param(
  [ValidateSet("Check", "Blocks", "All")]
  [string]$Mode = "All",
  [string]$ToolRoot = "",
  [string]$Liberty = "",
  [string]$BuildRoot = "",
  [string]$BlockFilter = "",
  [int]$TargetDelayPs = 10000,
  [switch]$IncludeWholeTop
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (!$ToolRoot) {
  $ToolRoot = if ($env:OSS_CAD_SUITE) {
    $env:OSS_CAD_SUITE
  } else {
    "C:\rv_toolchains\oss-cad-suite"
  }
}
if (!$Liberty) {
  $Liberty = if ($env:NANGATE45_LIBERTY) {
    $env:NANGATE45_LIBERTY
  } else {
    "C:\rv_toolchains\libs\nangate45\NangateOpenCellLibrary_typical.lib"
  }
}
if (!$BuildRoot) {
  $BuildRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rv_ooo_open_timing"
}

$yosys = Join-Path $ToolRoot "bin\yosys.exe"
$abc = Join-Path $ToolRoot "bin\yosys-abc.exe"
if (!(Test-Path -LiteralPath $yosys)) {
  throw "Yosys was not found: $yosys"
}
if (!(Test-Path -LiteralPath $abc)) {
  throw "ABC was not found: $abc"
}
if (!(Test-Path -LiteralPath $Liberty)) {
  throw "Liberty file was not found: $Liberty"
}

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$tempRoot = Join-Path $BuildRoot "tmp"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$env:TEMP = $tempRoot
$env:TMP = $tempRoot
$env:PATH = ((Join-Path $ToolRoot "bin") + ";" +
             (Join-Path $ToolRoot "lib") + ";" + $env:PATH)

function To-YosysPath([string]$Path) {
  return ([System.IO.Path]::GetFullPath($Path)).Replace("\", "/")
}

# Keep repository-owned inputs relative to the repository working directory.
# The Windows ABC executable cannot reopen a constraint path containing a
# non-ASCII user/profile directory even though Yosys itself can.
$sourceList = "sim/xcelium/sources_core.f"
$constraint = "synth/open_source/nangate45_abc.constr"
$libertyPath = To-YosysPath $Liberty
$abcPath = To-YosysPath $abc
$results = @()

function Invoke-YosysRun([string]$Name, [string]$Command) {
  $runDir = Join-Path $BuildRoot $Name
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null
  $logPath = Join-Path $runDir "synth.log"
  $consolePath = Join-Path $runDir "console.log"
  Push-Location $repoRoot
  try {
    # Windows PowerShell converts native stderr into terminating ErrorRecord
    # objects when the caller uses Stop.  Yosys/ABC emits harmless fallback
    # warnings on stderr, so the native exit code is authoritative here.
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $yosys -q -l $logPath -p $Command *> $consolePath
    $yosysExit = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorAction
    if ($yosysExit -ne 0) {
      Get-Content -LiteralPath $consolePath
      throw "Yosys failed for $Name; see $logPath"
    }
  } finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
  }
  return $logPath
}

if (($Mode -eq "Check") -or ($Mode -eq "All")) {
  $checkCommand =
    "read_slang --std 1800-2017 --single-unit --ignore-assertions " +
    "--ignore-initial --top rv_ooo_core -f $sourceList; " +
    "hierarchy -check -top rv_ooo_core; proc; check; stat"
  $checkLog = Invoke-YosysRun "rv_ooo_core_check" $checkCommand
  Write-Host "PASS rv_ooo_core structural check: $checkLog"
}

if (($Mode -eq "Blocks") -or ($Mode -eq "All")) {
  $blocks = @(
    @{ Name = "rv_writeback_arbiter"; Top = "rv_writeback_arbiter";
       Args = "-G SOURCE_COUNT=11"; Flow = "full" },
    @{ Name = "rv_lsq"; Top = "rv_lsq"; Args = ""; Flow = "macro" },
    @{ Name = "rv_fpu"; Top = "rv_fpu"; Args = ""; Flow = "full" },
    @{ Name = "rv_issue_queue"; Top = "rv_issue_queue";
       Args = "-G ENTRIES=56"; Flow = "macro" },
    @{ Name = "rv_rob"; Top = "rv_rob"; Args = ""; Flow = "macro" },
    @{ Name = "rv_rename2"; Top = "rv_rename2"; Args = ""; Flow = "full" },
    @{ Name = "rv_pmp"; Top = "rv_pmp"; Args = "-G CHECK_PORTS=8"; Flow = "full" },
    @{ Name = "rv_issue_arbiter"; Top = "rv_issue_arbiter";
       Args = "-G CANDIDATE_COUNT=2"; Flow = "full" }
  )
  if ($IncludeWholeTop) {
    # Whole-backend/core runs retain inferred memories as macro boundaries.
    # They can expand to hundreds of thousands of cells and take far longer
    # than leaf screening, so require an explicit opt-in.
    $blocks += @(
      @{ Name = "rv_backend"; Top = "rv_backend"; Args = ""; Flow = "macro" },
      @{ Name = "rv_ooo_core"; Top = "rv_ooo_core"; Args = ""; Flow = "macro" }
    )
  }
  if ($BlockFilter) {
    $blocks = @($blocks | Where-Object { $_.Name -eq $BlockFilter })
    if ($blocks.Count -eq 0) {
      throw "Unknown BlockFilter: $BlockFilter"
    }
  }

  foreach ($block in $blocks) {
    $mappedNetlist = To-YosysPath (
      (Join-Path (Join-Path $BuildRoot $block.Name) "mapped.v"))
    $preAbcRtlil = To-YosysPath (
      (Join-Path (Join-Path $BuildRoot $block.Name) "pre_abc.rtlil"))
    $front =
      "read_slang --std 1800-2017 --single-unit --ignore-assertions " +
      "--ignore-initial --top $($block.Top) $($block.Args) -f $sourceList; " +
      "hierarchy -check -top $($block.Top); "
    $lowering = if ($block.Flow -eq "macro") {
      "proc; flatten; opt -fast; memory_collect; techmap; opt -fast; "
    } else {
      "synth -top $($block.Top) -flatten -noshare -noabc; "
    }
    $command = $front + $lowering +
      "dfflibmap -liberty $libertyPath; " +
      "write_rtlil $preAbcRtlil; " +
      "abc -exe $abcPath -liberty $libertyPath -constr $constraint " +
      "-D $TargetDelayPs; clean; read_liberty -lib $libertyPath; " +
      "check; stat -liberty $libertyPath; " +
      "write_verilog -noattr -noexpr $mappedNetlist"
    $logPath = Invoke-YosysRun $block.Name $command
    $text = Get-Content -LiteralPath $logPath -Raw
    $delayMatch = [regex]::Match($text, "Delay\s*=\s*([0-9.]+)\s*ps")
    $areaMatch = [regex]::Match(
      $text, "Chip area for module '[^']+':\s*([0-9.]+)")
    $pathMatch = [regex]::Match(
      $text, "Start-point\s*=\s*([^\r\n]+)")
    $delay = if ($delayMatch.Success) { [double]$delayMatch.Groups[1].Value } else { $null }
    $area = if ($areaMatch.Success) { [double]$areaMatch.Groups[1].Value } else { $null }
    $results += [pscustomobject]@{
      Block = $block.Name
      Flow = $block.Flow
      DelayPs = $delay
      AreaUm2ExcludingMemories = $area
      CriticalPath = if ($pathMatch.Success) {
        $pathMatch.Groups[1].Value.Trim()
      } else { $null }
      Log = $logPath
    }
    Write-Host ("PASS {0,-24} delay={1,10} ps area={2,12} um^2" -f
      $block.Name, $delay, $area)
  }

  $summaryPath = Join-Path $BuildRoot "timing_summary.csv"
  $results | Export-Csv -LiteralPath $summaryPath -NoTypeInformation
  Write-Host "Timing summary: $summaryPath"
}
