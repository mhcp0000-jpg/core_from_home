param(
  [ValidateSet("Check", "Blocks", "All")]
  [string]$Mode = "All",
  [string]$ToolRoot = "",
  [string]$Liberty = "",
  [string]$BuildRoot = "",
  [string]$BlockFilter = "",
  [ValidateRange(1, 1000000)]
  [int]$TargetDelayPs = 1000,
  [switch]$EarlyLoadSelect = $true,
  [switch]$AguLoadBypass,
  [switch]$CompatiblePairSelect,
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

# Yosys/ABC on Windows cannot reopen output paths containing non-ASCII user
# directory names.  Runs live below the repository by default, so keep those
# paths relative to the repo working directory instead of expanding them.
function To-YosysOutputPath([string]$Path) {
  $full = [System.IO.Path]::GetFullPath($Path)
  $repo = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd("\")
  if ($full.StartsWith($repo + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($repo.Length + 1).Replace("\", "/")
  }
  return $full.Replace("\", "/")
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
  # Preserve the actual mapping budget and input identity. CSV delay alone
  # cannot support a fair comparison when ABC targets or libraries differ.
  $sourceIdentity = @(Get-Content -LiteralPath (Join-Path $repoRoot $sourceList) |
    Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") -and !$_.Trim().StartsWith("//") } |
    ForEach-Object {
      $sourceName = $_.Trim()
      [pscustomobject]@{ Path = $sourceName; Sha256 =
        (Get-FileHash -LiteralPath (Join-Path $repoRoot $sourceName) -Algorithm SHA256).Hash }
    })
  [pscustomobject]@{
    Block = $Name
    StartedUtc = [DateTime]::UtcNow.ToString("o")
    Command = $Command
    AbcTargetDelayPs = $TargetDelayPs
    Liberty = $Liberty
    LibertySha256 = (Get-FileHash -LiteralPath $Liberty -Algorithm SHA256).Hash
    ConstraintSha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $constraint) -Algorithm SHA256).Hash
    YosysSha256 = (Get-FileHash -LiteralPath $yosys -Algorithm SHA256).Hash
    AbcSha256 = (Get-FileHash -LiteralPath $abc -Algorithm SHA256).Hash
    Sources = $sourceIdentity
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir "run_manifest.json") -Encoding UTF8
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
    "--ignore-initial --top rv_ooo_core " +
    "-G EARLY_LOAD_SELECT=$(if ($EarlyLoadSelect) { 1 } else { 0 }) " +
    "-G AGU_LOAD_BYPASS=$(if ($AguLoadBypass) { 1 } else { 0 }) " +
    "-G COMPATIBLE_PAIR_SELECT=$(if ($CompatiblePairSelect) { 1 } else { 0 }) -f $sourceList; " +
    "hierarchy -check -top rv_ooo_core; proc; check; stat"
  $checkLog = Invoke-YosysRun "rv_ooo_core_check" $checkCommand
  Write-Host "PASS rv_ooo_core structural check: $checkLog"
}

if (($Mode -eq "Blocks") -or ($Mode -eq "All")) {
  $blocks = @(
    @{ Name = "rv_writeback_arbiter"; Top = "rv_writeback_arbiter";
       Args = "-G SOURCE_COUNT=11"; Flow = "full" },
    @{ Name = "rv_lsq"; Top = "rv_lsq"; Args = ""; Flow = "macro" },
    @{ Name = "rv_fpu"; Top = "rv_fpu"; Args = "-G LATENCY=5"; Flow = "full" },
    @{ Name = "rv_fpu6"; Top = "rv_fpu"; Args = "-G LATENCY=6"; Flow = "full" },
    @{ Name = "rv_issue_queue"; Top = "rv_issue_queue";
       Args = "-G ENTRIES=56 -G WRITEBACK_PORTS=8"; Flow = "macro" },
    @{ Name = "rv_rob"; Top = "rv_rob"; Args = "-G LIVE_QUERY_PORTS=11"; Flow = "macro" },
    @{ Name = "rv_rename2"; Top = "rv_rename2"; Args = ""; Flow = "full" },
    @{ Name = "rv_pmp"; Top = "rv_pmp"; Args = "-G CHECK_PORTS=8"; Flow = "full" },
    @{ Name = "rv_issue_arbiter"; Top = "rv_issue_arbiter";
       Args = "-G CANDIDATE_COUNT=2 -G AGE_ORDERED=1"; Flow = "full" },
    # These leaves were missing from the screening list, which is how
    # rv_store_buffer (6,014 ps) and rv_lsu_cluster (6,198 ps) stayed
    # invisible while shorter blocks were being optimized.
    @{ Name = "rv_store_buffer"; Top = "rv_store_buffer"; Args = ""; Flow = "full" },
    @{ Name = "rv_lsu_cluster"; Top = "rv_lsu_cluster"; Args = "-G AGU_DEPTH=2"; Flow = "macro" },
    @{ Name = "rv_multiplier"; Top = "rv_multiplier"; Args = ""; Flow = "full" },
    @{ Name = "rv_divider"; Top = "rv_divider"; Args = ""; Flow = "full" },
    @{ Name = "rv_fetch_queue"; Top = "rv_fetch_queue"; Args = ""; Flow = "full" },
    # Full frontend maps the queue/predictor/target-buffer arrays so the
    # count -> prediction -> redirect -> refill feedback path is visible.
    @{ Name = "rv_frontend"; Top = "rv_frontend"; Args = ""; Flow = "full";
       AbcScript = "trim" },
    @{ Name = "rv_csr_file"; Top = "rv_csr_file"; Args = ""; Flow = "full" },
    # Cover the execution/control/read-array logic in addition to queues.
    # PRF is fully mapped: macro flow would hide its asynchronous read mux.
    @{ Name = "rv_int_alu"; Top = "rv_int_alu"; Args = ""; Flow = "full" },
    @{ Name = "rv_int_alu64"; Top = "rv_int_alu"; Args = "-G XLEN=64"; Flow = "full" },
    @{ Name = "rv_branch_unit"; Top = "rv_branch_unit"; Args = ""; Flow = "full" },
    @{ Name = "rv_decode2"; Top = "rv_decode2"; Args = ""; Flow = "full" },
    @{ Name = "rv_trap_controller"; Top = "rv_trap_controller"; Args = ""; Flow = "full" },
    @{ Name = "rv_branch_recovery"; Top = "rv_branch_recovery"; Args = ""; Flow = "full" },
    @{ Name = "rv_int_prf"; Top = "rv_phys_regfile";
       Args = "-G PHYS_REGS=80 -G READ_PORTS=8 -G ZERO_REGISTER=1 -G WRITE_BYPASS=0";
       Flow = "full" },
    @{ Name = "rv_fp_prf"; Top = "rv_phys_regfile";
       Args = "-G PHYS_REGS=80 -G READ_PORTS=8 -G WRITE_BYPASS=0"; Flow = "full" },
    @{ Name = "rv_lsu_pipe"; Top = "rv_lsu_pipe"; Args = "-G DEPTH=2"; Flow = "full" },
    @{ Name = "rv_exec_result_buffer"; Top = "rv_exec_result_buffer";
       Args = "-G DEPTH=2"; Flow = "full" },
    @{ Name = "rv_fence_controller"; Top = "rv_fence_controller"; Args = ""; Flow = "full" }
  )
  if ($IncludeWholeTop) {
    # Whole-backend/core runs retain inferred memories as macro boundaries.
    # They can expand to hundreds of thousands of cells and take far longer
    # than leaf screening, so require an explicit opt-in.
    #
    # They are also the ONLY runs that see the cross-module critical path
    # (LSQ -> store_buffer -> writeback_arbiter -> IQ -> multiplier has no
    # register between the two ends), which is what the server STA reports.
    # yosys's default ABC script runs scorr/dc2/dretime/retime; on a ~610k
    # cell network those do not finish in any practical time -- that is the
    # "hang" seen earlier, not a tool failure.  AbcScript = "trim" swaps in a
    # delay-oriented script that completes in roughly half an hour.
    $blocks += @(
      @{ Name = "rv_backend"; Top = "rv_backend"; Args = ""; Flow = "macro";
         AbcScript = "trim" },
      @{ Name = "rv_ooo_core"; Top = "rv_ooo_core"; Args = ""; Flow = "macro";
         AbcScript = "trim" }
    )
  }
  if ($BlockFilter) {
    $requestedBlocks = @($BlockFilter.Split(',') | ForEach-Object { $_.Trim() })
    foreach ($requested in $requestedBlocks) {
      if ($requested -notin @($blocks | ForEach-Object { $_.Name })) {
        throw "Unknown BlockFilter: $requested"
      }
    }
    $blocks = @($blocks | Where-Object { $_.Name -in $requestedBlocks })
  }

  foreach ($block in $blocks) {
    if ($CompatiblePairSelect -and $block.Top -in @("rv_issue_queue", "rv_backend", "rv_ooo_core")) {
      $block.Args += " -G COMPATIBLE_PAIR_SELECT=1"
    }
    if ($block.Top -in @("rv_lsq", "rv_lsu_cluster", "rv_backend", "rv_ooo_core")) {
      $block.Args += " -G EARLY_LOAD_SELECT=$(if ($EarlyLoadSelect) { 1 } else { 0 })"
      $block.Args += " -G AGU_LOAD_BYPASS=$(if ($AguLoadBypass) { 1 } else { 0 })"
    }
    $mappedNetlist = To-YosysOutputPath (
      (Join-Path (Join-Path $BuildRoot $block.Name) "mapped.v"))
    $preAbcRtlil = To-YosysOutputPath (
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
    $abcOption = ""
    if ($block.ContainsKey("AbcScript") -and
        ($block.AbcScript -eq "trim")) {
      $blockDir = Join-Path $BuildRoot $block.Name
      New-Item -ItemType Directory -Force -Path $blockDir | Out-Null
      $abcScriptFile = Join-Path $blockDir "abc_trim.scr"
      # The delay target is written literally: ABC's own `source` does not
      # expand yosys placeholders such as {D}.
      Set-Content -LiteralPath $abcScriptFile -Encoding ASCII -Value @(
        "strash",
        "&get -n",
        "&dch -f",
        "&nf -D $TargetDelayPs",
        "&put",
        "buffer",
        "upsize -D $TargetDelayPs",
        "dnsize -D $TargetDelayPs",
        "stime -p")
      $abcOption = "-script " + (To-YosysPath $abcScriptFile) + " "
    }
    $command = $front + $lowering +
      "dfflibmap -liberty $libertyPath; " +
      "write_rtlil $preAbcRtlil; " +
      "abc -exe $abcPath " + $abcOption +
      "-liberty $libertyPath -constr $constraint " +
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
      Parameters = $block.Args
      AbcTargetDelayPs = $TargetDelayPs
      LibertySha256 = (Get-FileHash -LiteralPath $Liberty -Algorithm SHA256).Hash
      ConstraintSha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $constraint) -Algorithm SHA256).Hash
      MemoryModel = if ($block.Flow -eq "macro") { "unmapped arrays; read paths omitted" } else { "mapped flops" }
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
