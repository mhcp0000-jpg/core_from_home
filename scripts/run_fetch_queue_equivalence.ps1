param(
  [string]$Baseline = "2b17093",
  [string]$BuildRoot = "",
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [int]$BuildJobs = 2,
  # The minimum two-block ring aliases block head+2 back to head. Include
  # these cases when a head-lookahead implementation reads three blocks.
  [switch]$IncludeMinimumQueue
)
# Cycle-by-cycle ALL-output comparison with identical parameter settings.
# No benchmark-specific traffic: random C/32-bit bytes, faults, stalls,
# redirect+fill, wraparound, and repeated reset are exercised.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$drive = @("Z", "Y", "X", "W", "U", "T", "S", "R") |
  Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1
if (!$drive) { throw "No unused drive letter" }
$oldPath = $env:PATH
$oldRoot = $env:VERILATOR_ROOT
$locationPushed=$false
try {
  & subst "$drive`:" $repo
  if ($LASTEXITCODE) { throw "subst failed" }
  Push-Location "$drive`:/"
  $locationPushed=$true
  if (!$BuildRoot) { $BuildRoot = "$drive`:/out/fetch_queue_equivalence" }
  New-Item -ItemType Directory -Force $BuildRoot | Out-Null
  $ref = & git show "${Baseline}:rtl/frontend/rv_fetch_queue.sv"
  if ($LASTEXITCODE) { throw "Cannot read baseline $Baseline" }
  $ref = ($ref -join "`n") -replace "module rv_fetch_queue\b", "module rv_fetch_queue_ref"
  $refPath = "$BuildRoot/reference.sv"
  [IO.File]::WriteAllText($refPath, $ref, [Text.UTF8Encoding]::new($false))
  # Every geometry must test exactly the same bytes, even if the worktree
  # changes while a long matrix is running. Use immutable per-run snapshots.
  $candidatePath = "$BuildRoot/candidate.sv"
  $testbenchPath = "$BuildRoot/testbench.sv"
  $packagePath = "$BuildRoot/rv_ooo_pkg.sv"
  Copy-Item -LiteralPath rtl/frontend/rv_fetch_queue.sv -Destination $candidatePath -Force
  Copy-Item -LiteralPath tb/unit/frontend/rv_fetch_queue_equiv_tb.sv -Destination $testbenchPath -Force
  Copy-Item -LiteralPath rtl/rv_ooo_pkg.sv -Destination $packagePath -Force
  $configurations = @(@(32,16,64), @(64,16,64), @(32,8,32), @(64,32,128))
  if ($IncludeMinimumQueue) {
    $configurations += @(@(32,8,16), @(64,16,32))
  }
  @{
    referenceCommit=(& git rev-parse $Baseline)
    candidateSha256=(Get-FileHash $candidatePath -Algorithm SHA256).Hash
    testbenchSha256=(Get-FileHash $testbenchPath -Algorithm SHA256).Hash
    packageSha256=(Get-FileHash $packagePath -Algorithm SHA256).Hash
    inputPolicy="Immutable candidate/testbench/package snapshots in BuildRoot"
    cyclesPerConfiguration=60000
    configurations=($configurations.Count * 4)
    scope="Stateful all-public-output comparison, including invalid payload; not ISA proof"
  } | ConvertTo-Json | Set-Content "$BuildRoot/run_manifest.json" -Encoding UTF8
  $env:PATH = "$W64DevkitRoot/bin;" + $oldPath
  $env:VERILATOR_ROOT = $VerilatorRoot
  $top = "rv_fetch_queue_equiv_tb"
  foreach ($config in $configurations) {
    foreach($ungated in @(0,1)) { foreach($separate in @(0,1)) {
    $xlen, $fetch, $queue = $config
    $build = "$BuildRoot/x${xlen}_f${fetch}_q${queue}_u${ungated}_s${separate}"
    New-Item -ItemType Directory -Force $build | Out-Null
    $ErrorActionPreference = "Continue"
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal -Werror-UNOPTFLAT --top-module $top --Mdir $build "-GXLEN=$xlen" "-GFETCH_BYTES=$fetch" "-GQUEUE_BYTES=$queue" "-GUNGATED_PAYLOAD=$ungated" "-GSEPARATE_NORMAL_FILL_ADDRESS=$separate" $packagePath $refPath $candidatePath $testbenchPath *> "$build/compile.log"
    $generateCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($generateCode) { throw "Generation failed: $build/compile.log" }
    $ErrorActionPreference = "Continue"
    & "$W64DevkitRoot/bin/make.exe" -j $BuildJobs -C $build -f "V$top.mk" CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$build/build.log"
    $buildCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($buildCode) { throw "Build failed: $build/build.log" }
    & "$build/V$top.exe" | Tee-Object "$build/result.log"
    if ($LASTEXITCODE) { throw "Queue equivalence failed: $build/result.log" }
    }}
  }
} finally {
  if ($locationPushed) { Pop-Location }
  $env:PATH = $oldPath
  $env:VERILATOR_ROOT = $oldRoot
  & subst "$drive`:" /d | Out-Null
}
