param(
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [string]$BuildRoot = "C:\rv_build\block_tests",
  [switch]$RtlAssertions,
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4,
  [string[]]$OnlyTests = @(),
  [string]$SourceRoot = '',
  [string]$FixtureRoot = '',
  [switch]$SnapshotInputs
)

$ErrorActionPreference = "Stop"

$verilator = Join-Path $VerilatorRoot "bin\verilator_bin.exe"
$make = Join-Path $W64DevkitRoot "bin\make.exe"
$gxx = Join-Path $W64DevkitRoot "bin\g++.exe"
if (!(Test-Path -LiteralPath $verilator)) {
  throw "Verilator was not found at $verilator. Pass -VerilatorRoot."
}
if (!(Test-Path -LiteralPath $make) -or !(Test-Path -LiteralPath $gxx)) {
  throw "w64devkit was not found below $W64DevkitRoot. Pass -W64DevkitRoot."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repoRoot}
$sourceFull=(Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
if(!$FixtureRoot){$FixtureRoot=$sourceFull}
$fixtureFull=(Resolve-Path -LiteralPath $FixtureRoot).Path.TrimEnd('\')
$repoFull=(Resolve-Path -LiteralPath $repoRoot).Path.TrimEnd('\')
if($sourceFull -ne $repoFull -and !$sourceFull.StartsWith($repoFull+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'SourceRoot must be inside this workspace'
}
if($fixtureFull -ne $repoFull -and !$fixtureFull.StartsWith($repoFull+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'FixtureRoot must be inside this workspace'
}
if($SnapshotInputs -and !$PSBoundParameters.ContainsKey('BuildRoot')){
  $BuildRoot=Join-Path $repoFull 'out/block_tests_snapshot'
}
$buildFull=[IO.Path]::GetFullPath($BuildRoot)
if($SnapshotInputs){
  if(!$buildFull.StartsWith($repoFull+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw 'Snapshot BuildRoot must be below this workspace; use its resolved path'
  }
  if(Test-Path -LiteralPath $buildFull){throw 'Snapshot BuildRoot already exists; preserve earlier observations'}
}
$sourceRelative=if($sourceFull -eq $repoFull){''}else{$sourceFull.Substring($repoFull.Length+1).Replace('\','/')+'/'}
$drive = $null
foreach ($letter in @("Z", "Y", "X", "W", "U", "T", "S", "R")) {
  if (!(Test-Path "$letter`:\")) {
    $drive = "$letter`:"
    break
  }
}
if (!$drive) { throw "No unused drive letter is available." }

$tests = @(
  @{
    Top = "rv_csr_file_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_csr_file.sv",
              "tb/unit/backend/rv_csr_file_tb.sv")
  },
  @{
    Top = "rv_branch_arithmetic_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_branch_unit.sv",
              "tb/unit/backend/rv_branch_arithmetic_tb.sv")
  },
  @{
    Top = "rv_rob_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_rob.sv",
              "tb/unit/backend/rv_rob_tb.sv")
  },
  @{
    Top = "rv_issue_queue_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_issue_queue.sv",
              "tb/unit/backend/rv_issue_queue_tb.sv")
  },
  @{
    Top = "rv_issue_arbiter_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_issue_arbiter.sv",
              "tb/unit/backend/rv_issue_arbiter_tb.sv")
  },
  @{
    Top = "rv_issue_arbiter_equiv_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_issue_arbiter.sv",
              "tb/unit/backend/rv_issue_arbiter_equiv_tb.sv")
  },
  @{
    Top = "rv_issue_queue_tb"
    ParameterArgs = @("-GCompatiblePairSelect=1")
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_issue_queue.sv",
              "tb/unit/backend/rv_issue_queue_tb.sv")
  },
  @{
    Top = "rv_decode2_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/frontend/rv_c_expander.sv",
              "rtl/backend/rv_decode2.sv",
              "tb/unit/backend/rv_decode2_tb.sv")
  },
  @{
    Top = "rv_store_buffer_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_store_buffer.sv",
              "tb/unit/backend/rv_store_buffer_tb.sv")
  },
  @{
    Top = "rv_lsq_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_lsq.sv",
              "tb/unit/backend/rv_lsq_tb.sv")
  },
  @{
    Top = "rv_writeback_arbiter_tb"
    Files = @("rtl/rv_ooo_pkg.sv",
              "rtl/backend/rv_writeback_arbiter.sv",
              "tb/unit/backend/rv_writeback_arbiter_tb.sv")
  },
  @{
    Top = "rv_lsq_tb"
    ParameterArgs = @("-GEarlyLoadSelect=1")
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_lsq.sv",
              "tb/unit/backend/rv_lsq_tb.sv")
  },
  @{
    Top = "rv_multiplier_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/backend/rv_multiplier.sv",
              "tb/unit/backend/rv_multiplier_tb.sv")
  },
  @{
    Top = "rv_branch_predictor_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/frontend/rv_branch_predictor.sv",
              "tb/unit/frontend/rv_branch_predictor_tb.sv")
  },
  @{
    Top = "rv_branch_target_arithmetic_tb"
    Files = @("rtl/rv_ooo_pkg.sv", "rtl/frontend/rv_branch_predictor.sv",
              "tb/unit/frontend/rv_branch_target_arithmetic_tb.sv")
  },
  @{
    Top = "rv_fetch_target_buffer_tb"
    Files = @("rtl/frontend/rv_fetch_target_buffer.sv",
              "tb/unit/frontend/rv_fetch_target_buffer_tb.sv")
  },
  @{
    Top = "rv_axi_bridge_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_axi4_if.sv",
      "rtl/soc/rv_local_mem_if.sv", "rtl/soc/rv_local_to_axi_bridge.sv",
      "rtl/soc/rv_axi_to_local_bridge.sv", "tb/unit/soc/rv_axi_bridge_tb.sv"
    )
  },
  @{
    Top = "rv_axi_to_local_burst_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_axi4_if.sv",
      "rtl/soc/rv_local_mem_if.sv", "rtl/soc/rv_axi_to_local_bridge.sv",
      "tb/unit/soc/rv_axi_bridge_tb.sv"
    )
  },
  @{
    Top = "rv_d_fabric_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_local_mem_if.sv",
      "rtl/soc/rv_sram_1r1w.sv", "rtl/soc/rv_tim_2bank.sv",
      "rtl/soc/rv_clint.sv", "rtl/soc/rv_d_fabric.sv",
      "tb/unit/soc/rv_d_fabric_tb.sv"
    )
  },
  @{
    Top = "rv_i_fabric_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_local_mem_if.sv",
      "rtl/soc/rv_sram_1r1w.sv", "rtl/soc/rv_tim_2bank.sv",
      "rtl/soc/rv_bootrom.sv", "rtl/soc/rv_i_fabric.sv",
      "tb/unit/soc/rv_i_fabric_tb.sv"
    )
  },
  @{
    Top = "rv_soc_peripheral_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_local_mem_if.sv",
      "rtl/soc/rv_sram_1r1w.sv", "rtl/soc/rv_bootrom.sv",
      "rtl/soc/rv_hostif.sv", "tb/unit/soc/rv_soc_peripheral_tb.sv"
    )
  },
  @{
    Top = "rv_plic_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_axi4_if.sv", "rtl/soc/rv_local_mem_if.sv",
      "rtl/soc/rv_axi_to_local_bridge.sv", "rtl/soc/rv_plic.sv",
      "tb/unit/soc/rv_plic_tb.sv"
    )
  },
  @{
    Top = "rv_clint_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_local_mem_if.sv", "rtl/soc/rv_clint.sv",
      "tb/unit/soc/rv_clint_tb.sv"
    )
  }
)

$frontendFiles = @("rtl/rv_ooo_pkg.sv", "rtl/frontend/rv_fetch_queue.sv",
  "rtl/frontend/rv_branch_predictor.sv", "rtl/frontend/rv_fetch_target_buffer.sv",
  "rtl/frontend/rv_frontend.sv", "tb/unit/frontend/rv_frontend_cross_block_tb.sv")
foreach ($configuration in @(@(), @("-GXLEN=64"), @("-GXLEN=64", "-GPADDR_WIDTH=32"))) {
  $tests += @{ Top = "rv_frontend_cross_block_tb"; ParameterArgs = $configuration; Files = $frontendFiles }
}
foreach ($early in @(0, 1)) {
  $tests += @{ Top = "rv_lsq_tb"; ParameterArgs = @("-GEarlyLoadSelect=$early", "-GAguLoadBypass=1"); Files = @(
    "rtl/rv_ooo_pkg.sv", "rtl/backend/rv_lsq.sv", "tb/unit/backend/rv_lsq_tb.sv") }
}

# Exercise actual arithmetic-stage boundaries, not just the compact unit pipe.
foreach ($latency in @(2, 5, 6)) {
  $tests += @{ Top = "rv_fpu_tb"; ParameterArgs = @("-GFpuLatency=$latency"); Files = @(
    "rtl/rv_ooo_pkg.sv", "rtl/backend/rv_fpu.sv", "tb/unit/backend/rv_fpu_tb.sv") }
}
foreach ($width in @(32, 64)) {
  $tests += @{ Top = "rv_pmp_tb"; ParameterArgs = @("-GPADDR_WIDTH=$width"); Files = @(
    "rtl/rv_ooo_pkg.sv", "rtl/backend/rv_pmp.sv", "tb/unit/backend/rv_pmp_tb.sv") }
  $tests += @{ Top = "rv_exec_result_buffer_depth2_tb"; ParameterArgs = @("-GXLEN=$width"); Files = @(
    "rtl/rv_ooo_pkg.sv", "rtl/backend/rv_exec_result_buffer.sv",
    "tb/unit/backend/rv_exec_result_buffer_depth2_tb.sv") }
}

foreach ($ports in @(2, 3, 4, 6)) {
  $tests += @{ Top = "rv_issue_arbiter_equiv_tb"; ParameterArgs = @("-GExecPorts=$ports"); Files = @(
    "rtl/rv_ooo_pkg.sv", "rtl/backend/rv_issue_arbiter.sv", "tb/unit/backend/rv_issue_arbiter_equiv_tb.sv") }
}

if ($OnlyTests.Count) {
  $unknownTests = @($OnlyTests | Where-Object { $_ -notin $tests.Top })
  if ($unknownTests.Count) { throw "Unknown test names: $($unknownTests -join ', ')" }
  $tests = @($tests | Where-Object { $_.Top -in $OnlyTests })
}
New-Item -ItemType Directory -Force -Path $buildFull | Out-Null
$report=$null
if($SnapshotInputs){
  $dataInputs=@()
  if('rv_i_fabric_tb' -in $tests.Top -or 'rv_soc_peripheral_tb' -in $tests.Top){
    $relative='tb/fixtures/bootrom/bootrom_test.hex'
    $original=Join-Path $fixtureFull $relative
    if(!(Test-Path -LiteralPath $original)){throw 'Missing BootROM fixture; pass -FixtureRoot explicitly for a partial RTL snapshot'}
    $frozen=Join-Path "$buildFull/inputs" $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $frozen) | Out-Null
    Copy-Item -LiteralPath $original -Destination $frozen
    $dataInputs+=@{Path=$relative;Sha256=(Get-FileHash -LiteralPath $frozen).Hash}
  }
  $inputs=@($tests | ForEach-Object {$_.Files} | Sort-Object -Unique | ForEach-Object {
    $relative=$_.ToString()
    $original=Join-Path $sourceFull $relative
    $frozen=Join-Path "$buildFull/inputs" $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $frozen) | Out-Null
    Copy-Item -LiteralPath $original -Destination $frozen
    @{Path=$relative;Sha256=(Get-FileHash -LiteralPath $frozen).Hash}
  })
  $report=@{passed=$false;expectedTests=$tests.Count;cases=[Collections.Generic.List[object]]::new();
    sourceRoot=$sourceFull;inputs=$inputs;fixtureRoot=$fixtureFull;runtimeDataInputs=$dataInputs;assertionsEnabled=[bool]$RtlAssertions;
    runnerSha256=(Get-FileHash $PSCommandPath).Hash;
    verilatorSha256=(Get-FileHash $verilator).Hash;makeSha256=(Get-FileHash $make).Hash;
    gxxSha256=(Get-FileHash $gxx).Hash;
    scope='Finite block tests with immutable RTL/TB and selected BootROM runtime inputs, per-case native exits. Simulation cwd is frozen inputs/. Explicit unit geometry sweeps are NOT core parameter overrides, full ISA/X proof, or timing.'}
  $report | ConvertTo-Json -Depth 8 | Set-Content "$buildFull/report.json" -Encoding UTF8
}
try {
  & subst $drive $repoRoot
  if ($LASTEXITCODE -ne 0) { throw "Failed to map $repoRoot to $drive." }

  $oldVerilatorRoot = $env:VERILATOR_ROOT
  $oldPath = $env:PATH
  try {
    $env:VERILATOR_ROOT = $VerilatorRoot
    $env:PATH = (Join-Path $W64DevkitRoot "bin") + ";" + $oldPath
    $caseNumber=0
    $toolBuild=if($SnapshotInputs){"$drive/"+$buildFull.Substring($repoFull.Length+1).Replace('\','/')}else{$BuildRoot}
    foreach ($test in $tests) {
      if ($OnlyTests.Count -and $test.Top -notin $OnlyTests) { continue }
      $caseNumber++
      $caseName=if($SnapshotInputs){'{0:D2}_{1}' -f $caseNumber,$test.Top}else{$test.Top}
      $testBuild = Join-Path $toolBuild $caseName
      New-Item -ItemType Directory -Force -Path $testBuild | Out-Null
      $mappedSources = $test.Files | ForEach-Object {
        if($SnapshotInputs){"$toolBuild/inputs/"+($_ -replace '\\','/')}
        else{"$drive/"+$sourceRelative+($_ -replace '\\','/')}
      }

      Write-Host "`n=== $($test.Top) ==="
      $assertionOption = if ($RtlAssertions) { "--assert" } else { "-DSYNTHESIS" }
      [string[]]$testArgs = @()
      if ($test.ContainsKey("ParameterArgs")) { $testArgs = @($test.ParameterArgs) }
      if($SnapshotInputs){
        $observation=@{case=$caseName;top=$test.Top;unitParameterArgs=$testArgs;
          compileExit=$null;buildExit=$null;nativeExit=$null;passed=$false}
        $report.cases.Add($observation)
        & $verilator --cc --exe --timing --main $assertionOption -Wno-fatal `
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module $test.Top `
          --Mdir $testBuild @testArgs @mappedSources *> "$testBuild/compile.log"
        $observation.compileExit=$LASTEXITCODE
        $report | ConvertTo-Json -Depth 8 | Set-Content "$buildFull/report.json" -Encoding UTF8
      }else{
        & $verilator --cc --exe --timing --main $assertionOption -Wno-fatal `
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module $test.Top `
          --Mdir $testBuild @testArgs @mappedSources
      }
      if ($LASTEXITCODE -ne 0) {
        throw "Verilator code generation failed: $($test.Top)"
      }

      if($SnapshotInputs){
        & $make -j $BuildJobs -C $testBuild -f "V$($test.Top).mk" `
          CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$testBuild/build.log"
        $observation.buildExit=$LASTEXITCODE
        $report | ConvertTo-Json -Depth 8 | Set-Content "$buildFull/report.json" -Encoding UTF8
      }else{
        & $make -j $BuildJobs -C $testBuild -f "V$($test.Top).mk" `
          CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1
      }
      if ($LASTEXITCODE -ne 0) {
        throw "Verilator C++ build failed: $($test.Top)"
      }

      $simulation = Join-Path $testBuild "V$($test.Top).exe"
      if($SnapshotInputs){
        Push-Location "$toolBuild/inputs"
        try {
          & $simulation *> "$testBuild/result.log"
          $observation.nativeExit=$LASTEXITCODE
          $observation.passed=$LASTEXITCODE -eq 0
        } finally {Pop-Location}
        $observation.logs=@{}
        foreach($file in @('compile.log','build.log','result.log')){
          $observation.logs[$file]=(Get-FileHash "$testBuild/$file").Hash
        }
        $report | ConvertTo-Json -Depth 8 | Set-Content "$buildFull/report.json" -Encoding UTF8
      }else{& $simulation}
      if ($LASTEXITCODE -ne 0) {
        throw "Simulation failed: $($test.Top)"
      }
      Write-Host "PASS $($test.Top)"
    }
    if($SnapshotInputs){
      $report.sourceUnchangedAtEnd=$true
      foreach($s in $report.inputs){
        if((Get-FileHash (Join-Path $sourceFull $s.Path)).Hash -ne $s.Sha256 -or
           (Get-FileHash (Join-Path "$buildFull/inputs" $s.Path)).Hash -ne $s.Sha256){
          $report.sourceUnchangedAtEnd=$false
        }
      }
      foreach($s in $report.runtimeDataInputs){
        if((Get-FileHash (Join-Path $fixtureFull $s.Path)).Hash -ne $s.Sha256 -or
           (Get-FileHash (Join-Path "$buildFull/inputs" $s.Path)).Hash -ne $s.Sha256){
          $report.sourceUnchangedAtEnd=$false
        }
      }
      $report.passed=$report.sourceUnchangedAtEnd -and $report.cases.Count -eq $report.expectedTests -and
        @($report.cases | Where-Object {!$_.passed -or $_.compileExit -ne 0 -or $_.buildExit -ne 0 -or $_.nativeExit -ne 0}).Count -eq 0
      $report | ConvertTo-Json -Depth 8 | Set-Content "$buildFull/report.json" -Encoding UTF8
      if(!$report.passed){throw 'Block snapshot/source/native qualification incomplete'}
    }
  } finally {
    $env:VERILATOR_ROOT = $oldVerilatorRoot
    $env:PATH = $oldPath
  }
} finally {
  if ($drive) { & subst $drive /d | Out-Null }
}

Write-Host "`nBLOCK REGRESSION PASS ($($tests.Count) tests)"
