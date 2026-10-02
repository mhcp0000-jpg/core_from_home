param(
  [string]$Baseline = "081e714",
  [string]$CandidatePath = "",
  [string]$BuildRoot = "",
  [string]$ToolRoot = "C:\rv_toolchains\oss-cad-suite",
  [switch]$IncludeMinimumQueue
)
# Two-state one-step equivalence of every matched signal/output/state bit.
# This is not ISA proof or four-state simulation; use the random/SVA runner too.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
if (!$CandidatePath) { $CandidatePath = Join-Path $repoRoot "rtl/frontend/rv_fetch_queue.sv" }
if (!$BuildRoot) { $BuildRoot = Join-Path $repoRoot "out/fetch_queue_formal" }
$candidateFull = (Resolve-Path -LiteralPath $CandidatePath).Path
$buildFull = [IO.Path]::GetFullPath($BuildRoot)
$yosys = Join-Path $ToolRoot "bin/yosys.exe"
if (!(Test-Path -LiteralPath $yosys)) { throw "Missing Yosys: $yosys" }
$drive = @("Z", "Y", "X", "W", "U", "T", "S", "R") |
  Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1
if (!$drive) { throw "No unused drive letter" }
$savedPath = $env:PATH
$pushed = $false
try {
  & subst "$drive`:" $repoRoot
  if ($LASTEXITCODE) { throw "subst failed" }
  Push-Location "$drive`:/"
  $pushed = $true
  # Repository-local outputs use the ASCII drive alias, including profile paths.
  $repoFull = [IO.Path]::GetFullPath($repoRoot).TrimEnd("\")
  $runRoot = $buildFull
  if ($buildFull.StartsWith($repoFull + "\", [StringComparison]::OrdinalIgnoreCase)) {
    $runRoot = "$drive`:/" + $buildFull.Substring($repoFull.Length + 1).Replace("\", "/")
  }
  New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
  $reference = & git show "${Baseline}:rtl/frontend/rv_fetch_queue.sv"
  if ($LASTEXITCODE) { throw "Cannot read baseline $Baseline" }
  $reference = ($reference -join "`n") -replace "module rv_fetch_queue\b", "module rv_fetch_queue_ref"
  [IO.File]::WriteAllText("$runRoot/reference.sv", $reference, [Text.UTF8Encoding]::new($false))
  Copy-Item -LiteralPath $candidateFull -Destination "$runRoot/candidate.sv" -Force
  Copy-Item -LiteralPath rtl/rv_ooo_pkg.sv -Destination "$runRoot/rv_ooo_pkg.sv" -Force
  $shapes = @(@(32,16,64), @(64,16,64), @(32,8,32), @(64,32,128))
  if ($IncludeMinimumQueue) { $shapes += @(@(32,8,16), @(64,16,32)) }
  @{
    referenceCommit = (& git rev-parse $Baseline)
    candidateSha256 = (Get-FileHash "$runRoot/candidate.sv" -Algorithm SHA256).Hash
    packageSha256 = (Get-FileHash "$runRoot/rv_ooo_pkg.sv" -Algorithm SHA256).Hash
    yosysSha256 = (Get-FileHash $yosys -Algorithm SHA256).Hash
    inputPolicy = "Immutable reference/candidate/package snapshots"
    configurations = $shapes.Count * 4
    scope = "Yosys equiv_make/equiv_simple seq1; all matched outputs and common state, two-state; not ISA or four-state proof"
  } | ConvertTo-Json | Set-Content "$runRoot/run_manifest.json" -Encoding UTF8
  $env:PATH = (Join-Path $ToolRoot "lib") + ";" + $savedPath
  $rtlRoot = $runRoot.Replace("\", "/")
  foreach ($shape in $shapes) {
    $xlen, $fetch, $queue = $shape
    foreach ($ungated in @(0,1)) { foreach ($separate in @(0,1)) {
      $name = "x${xlen}_f${fetch}_q${queue}_u${ungated}_s${separate}"
      $parameters = "-G XLEN=$xlen -G FETCH_BYTES=$fetch -G QUEUE_BYTES=$queue " +
                    "-G UNGATED_PAYLOAD=$ungated -G SEPARATE_NORMAL_FILL_ADDRESS=$separate"
      $common = "--std 1800-2017 --ignore-assertions --ignore-initial"
      $command = "read_slang $common --top rv_fetch_queue_ref $parameters " +
        "`"$rtlRoot/rv_ooo_pkg.sv`" `"$rtlRoot/reference.sv`"; " +
        "prep -top rv_fetch_queue_ref; memory_map; opt_clean; design -stash gold; " +
        "read_slang $common --top rv_fetch_queue $parameters " +
        "`"$rtlRoot/rv_ooo_pkg.sv`" `"$rtlRoot/candidate.sv`"; " +
        "prep -top rv_fetch_queue; memory_map; opt_clean; design -stash gate; " +
        "design -copy-from gold -as gold rv_fetch_queue_ref; " +
        "design -copy-from gate -as gate rv_fetch_queue; " +
        "equiv_make gold gate equiv; hierarchy -top equiv; " +
        "equiv_simple -seq 1; equiv_status -assert"
      $ErrorActionPreference = "Continue"
      & $yosys -Q -T -p $command *> "$runRoot/$name.log"
      $proofExit = $LASTEXITCODE
      $ErrorActionPreference = "Stop"
      if ($proofExit) { throw "Equivalence failed: $runRoot/$name.log" }
      if (!(Select-String -LiteralPath "$runRoot/$name.log" -Pattern "Equivalence successfully proven!" -Quiet)) {
        throw "No completed equivalence proof in $name.log"
      }
      Write-Host "PASS fetch queue formal $name"
    }}
  }
} finally {
  $env:PATH = $savedPath
  if ($pushed) { Pop-Location }
  & subst "$drive`:" /d | Out-Null
}
