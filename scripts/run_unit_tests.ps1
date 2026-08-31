param(
  [string]$IverilogPath = ""
)

# Windows PowerShell maps native stderr to ErrorRecord objects. Icarus emits
# supported-feature notices on stderr even when compilation succeeds, so native
# exit codes below are the authoritative pass/fail result.
$ErrorActionPreference = "Continue"

if ($IverilogPath) {
  $iverilog = $IverilogPath
} else {
  $command = Get-Command iverilog -ErrorAction SilentlyContinue
  if ($command) {
    $iverilog = $command.Source
  } elseif (Test-Path -LiteralPath "C:\iverilog\bin\iverilog.exe") {
    $iverilog = "C:\iverilog\bin\iverilog.exe"
  } else {
    throw "iverilog.exe was not found. Install Icarus Verilog or pass -IverilogPath."
  }
}

$vvp = Join-Path (Split-Path -Parent $iverilog) "vvp.exe"
if (!(Test-Path -LiteralPath $vvp)) {
  throw "vvp.exe was not found next to $iverilog."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rv_ooo_unit_tests"
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$tests = @(
  @{
    Top = "rv_decode2_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/frontend/rv_c_expander.sv",
      "rtl/backend/rv_decode2.sv",
      "tb/unit/rv_decode2_tb.sv"
    )
  },
  @{
    Top = "rv_divider_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_divider.sv",
      "tb/unit/rv_divider_tb.sv"
    )
  },
  @{
    Top = "rv_fpu_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_fpu.sv",
      "tb/unit/rv_fpu_tb.sv"
    )
  },
  @{
    Top = "rv_fetch_queue_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/frontend/rv_fetch_queue.sv",
      "tb/unit/rv_fetch_queue_tb.sv"
    )
  },
  @{
    Top = "rv_lsu_pipe_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_lsu_pipe.sv",
      "tb/unit/rv_lsu_pipe_tb.sv"
    )
  },
  @{
    Top = "rv_store_buffer_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_store_buffer.sv",
      "tb/unit/rv_store_buffer_tb.sv"
    )
  },
  @{
    Top = "rv_lsq_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_lsq.sv",
      "tb/unit/rv_lsq_tb.sv"
    )
  },
  @{
    Top = "rv_writeback_arbiter_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_writeback_arbiter.sv",
      "tb/unit/rv_writeback_arbiter_tb.sv"
    )
  },
  @{
    Top = "rv_branch_recovery_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_branch_recovery.sv",
      "tb/unit/rv_branch_recovery_tb.sv"
    )
  },
  @{
    Top = "rv_exec_result_buffer_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_exec_result_buffer.sv",
      "tb/unit/rv_exec_result_buffer_tb.sv"
    )
  },
  @{
    Top = "rv_csr_file_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_csr_file.sv",
      "tb/unit/rv_csr_file_tb.sv"
    )
  },
  @{
    Top = "rv_pmp_tb"
    Files = @(
      "rtl/rv_ooo_pkg.sv",
      "rtl/backend/rv_pmp.sv",
      "tb/unit/rv_pmp_tb.sv"
    )
  }
)

Push-Location $repoRoot
try {
  foreach ($test in $tests) {
    $image = Join-Path $buildRoot ($test.Top + ".vvp")
    $compileLog = Join-Path $buildRoot ($test.Top + ".compile.log")
    & $iverilog -g2012 -DSYNTHESIS -s $test.Top -o $image @($test.Files) `
      *> $compileLog
    if ($LASTEXITCODE -ne 0) {
      Get-Content -LiteralPath $compileLog
      throw "Compile failed: $($test.Top)"
    }

    & $vvp $image
    if ($LASTEXITCODE -ne 0) {
      throw "Simulation failed: $($test.Top)"
    }
    Write-Host "PASS $($test.Top)"
  }
} finally {
  Pop-Location
}
