param(
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [string]$BuildRoot = "C:\rv_build\block_tests",
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4
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
    Top = "rv_axi_bridge_tb"
    Files = @(
      "rtl/soc/rv_soc_pkg.sv", "rtl/rv_ooo_pkg.sv",
      "rtl/soc/rv_axi4_if.sv",
      "rtl/soc/rv_local_mem_if.sv", "rtl/soc/rv_local_to_axi_bridge.sv",
      "rtl/soc/rv_axi_to_local_bridge.sv", "tb/unit/soc/rv_axi_bridge_tb.sv"
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

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

try {
  & subst $drive $repoRoot
  if ($LASTEXITCODE -ne 0) { throw "Failed to map $repoRoot to $drive." }

  $oldVerilatorRoot = $env:VERILATOR_ROOT
  $oldPath = $env:PATH
  try {
    $env:VERILATOR_ROOT = $VerilatorRoot
    $env:PATH = (Join-Path $W64DevkitRoot "bin") + ";" + $oldPath

    foreach ($test in $tests) {
      $testBuild = Join-Path $BuildRoot $test.Top
      New-Item -ItemType Directory -Force -Path $testBuild | Out-Null
      $mappedSources = $test.Files | ForEach-Object {
        "$drive/" + ($_ -replace '\\', '/')
      }

      Write-Host "`n=== $($test.Top) ==="
      & $verilator --cc --exe --timing --main -DSYNTHESIS -Wno-fatal `
        -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module $test.Top `
        --Mdir $testBuild @mappedSources
      if ($LASTEXITCODE -ne 0) {
        throw "Verilator code generation failed: $($test.Top)"
      }

      & $make -j $BuildJobs -C $testBuild -f "V$($test.Top).mk" `
        CXX=g++ CC=gcc LINK=g++
      if ($LASTEXITCODE -ne 0) {
        throw "Verilator C++ build failed: $($test.Top)"
      }

      $simulation = Join-Path $testBuild "V$($test.Top).exe"
      & $simulation
      if ($LASTEXITCODE -ne 0) {
        throw "Simulation failed: $($test.Top)"
      }
      Write-Host "PASS $($test.Top)"
    }
  } finally {
    $env:VERILATOR_ROOT = $oldVerilatorRoot
    $env:PATH = $oldPath
  }
} finally {
  if ($drive) { & subst $drive /d | Out-Null }
}

Write-Host "`nBLOCK REGRESSION PASS ($($tests.Count) tests)"
