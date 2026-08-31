param(
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [string]$BuildRoot = "C:\rv_build\backend_int"
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
if (!$drive) {
  throw "No unused drive letter is available for the ASCII-only Verilator build path."
}

$sources = @(
  "rtl/rv_ooo_pkg.sv",
  "rtl/frontend/rv_c_expander.sv",
  "rtl/backend/rv_decode2.sv",
  "rtl/backend/rv_rename2.sv",
  "rtl/backend/rv_phys_regfile.sv",
  "rtl/backend/rv_rob.sv",
  "rtl/backend/rv_issue_queue.sv",
  "rtl/backend/rv_issue_arbiter.sv",
  "rtl/backend/rv_int_alu.sv",
  "rtl/backend/rv_branch_unit.sv",
  "rtl/backend/rv_multiplier.sv",
  "rtl/backend/rv_divider.sv",
  "rtl/backend/rv_fpu.sv",
  "rtl/backend/rv_lsu_pipe.sv",
  "rtl/backend/rv_lsq.sv",
  "rtl/backend/rv_store_buffer.sv",
  "rtl/backend/rv_lsu_cluster.sv",
  "rtl/backend/rv_exec_result_buffer.sv",
  "rtl/backend/rv_writeback_arbiter.sv",
  "rtl/backend/rv_branch_recovery.sv",
  "rtl/backend/rv_csr_file.sv",
  "rtl/backend/rv_pmp.sv",
  "rtl/backend/rv_backend.sv",
  "tb/unit/rv_backend_int_tb.sv"
)

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

try {
  & subst $drive $repoRoot
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to map $repoRoot to $drive."
  }

  $mappedRoot = "$drive\"
  $mappedSources = $sources | ForEach-Object { Join-Path $mappedRoot $_ }
  $oldVerilatorRoot = $env:VERILATOR_ROOT
  try {
    $env:VERILATOR_ROOT = $VerilatorRoot
    & $verilator --cc --exe --timing --main -DSYNTHESIS -Wno-fatal `
      --top-module rv_backend_int_tb --Mdir $BuildRoot @mappedSources
    if ($LASTEXITCODE -ne 0) {
      throw "Verilator code generation failed."
    }
  } finally {
    $env:VERILATOR_ROOT = $oldVerilatorRoot
  }

  $oldPath = $env:PATH
  try {
    $env:PATH = (Join-Path $W64DevkitRoot "bin") + ";" + $oldPath
    & $make -C $BuildRoot -f Vrv_backend_int_tb.mk CXX=g++ CC=gcc LINK=g++
    if ($LASTEXITCODE -ne 0) {
      throw "Verilator C++ build failed."
    }
  } finally {
    $env:PATH = $oldPath
  }

  $simulation = Join-Path $BuildRoot "Vrv_backend_int_tb.exe"
  if (!(Test-Path -LiteralPath $simulation)) {
    throw "Expected simulation executable was not generated: $simulation"
  }
  & $simulation
  if ($LASTEXITCODE -ne 0) {
    throw "Integration simulation failed: rv_backend_int_tb"
  }
  Write-Host "PASS rv_backend_int_tb"
} finally {
  if ($drive) {
    & subst $drive /d | Out-Null
  }
}
