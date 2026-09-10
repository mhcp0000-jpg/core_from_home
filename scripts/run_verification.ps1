param(
  [string]$ArtifactRoot = "",
  [string]$SocElfBuildRoot = "",
  [string]$PythonPath = "",
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4,
  [ValidateRange(1, 1000000000)]
  [int]$TimeoutCycles = 20000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (!$ArtifactRoot) {
  $ArtifactRoot = Join-Path $repoRoot "out/verification"
}
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$powerShell = (Get-Process -Id $PID).Path

if ($PythonPath) {
  $python = $PythonPath
} else {
  $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
  if (!$pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
  }
  if (!$pythonCommand) {
    $pythonCommand = Get-Command py -ErrorAction SilentlyContinue
  }
  if ($pythonCommand) {
    $python = $pythonCommand.Source
  } elseif ($env:LOCALAPPDATA) {
    $localPython = Join-Path $env:LOCALAPPDATA `
      "Programs\Python\Python314\python.exe"
    if (Test-Path -LiteralPath $localPython) {
      $python = $localPython
    } else {
      throw "Python was not found. Pass -PythonPath or add python/python3 to PATH."
    }
  } else {
    throw "Python was not found. Pass -PythonPath or add python/python3 to PATH."
  }
}
if (!(Test-Path -LiteralPath $python)) {
  throw "Python was not found at $python. Pass -PythonPath."
}

if (!$SocElfBuildRoot) {
  $SocElfBuildRoot = Join-Path $ArtifactRoot "soc_elf_build"
}
$blockBuildRoot = Join-Path $ArtifactRoot "block_tests"
$backendBuildRoot = Join-Path $ArtifactRoot "backend_int"
$socBootBuildRoot = Join-Path $ArtifactRoot "soc_boot"
$elfPath = Join-Path $ArtifactRoot "rv32_smoke.elf"
$tracePath = Join-Path $ArtifactRoot "rv32_smoke_commit.csv"
$compressedElfPath = Join-Path $ArtifactRoot "rv32c_smoke.elf"
$compressedTracePath = Join-Path $ArtifactRoot "rv32c_smoke_commit.csv"
$privElfPath = Join-Path $ArtifactRoot "rv32_priv_smoke.elf"
$privTracePath = Join-Path $ArtifactRoot "rv32_priv_smoke_commit.csv"

function Invoke-Checked([string]$name, [scriptblock]$command) {
  Write-Host "`n=== $name ==="
  & $command
  if ($LASTEXITCODE -ne 0) { throw "$name failed with exit code $LASTEXITCODE." }
}

Push-Location $repoRoot
try {
  Invoke-Checked "RTL parse/elaboration" { & $python scripts/check_rtl.py }
  Invoke-Checked "FPU exact-vector manifest" {
    & $python scripts/gen_fpu_diff_vectors.py --check
  }
  Invoke-Checked "Unit regression" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_unit_tests.ps1
  }
  Invoke-Checked "Block regression" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_block_tests.ps1 `
      -BuildRoot $blockBuildRoot -BuildJobs $BuildJobs
  }
  Invoke-Checked "Backend integration" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_integration_tests.ps1 `
      -BuildRoot $backendBuildRoot
  }
  Invoke-Checked "Directed SoC boot" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_soc_boot_test.ps1 `
      -BuildRoot $socBootBuildRoot
  }
  Invoke-Checked "Build self-check ELF" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/build_rv32_smoke_elf.ps1 `
      -OutputPath $elfPath
  }
  Invoke-Checked "DPI ELF SoC" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_soc_elf_test.ps1 `
      -ElfPath $elfPath -TracePath $tracePath -BuildJobs $BuildJobs `
      -BuildRoot $SocElfBuildRoot -TimeoutCycles $TimeoutCycles
  }
  Invoke-Checked "Commit trace invariants" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/analyze_commit_trace.ps1 `
      -TracePath $tracePath
  }
  Invoke-Checked "RV32IMF architectural trace" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/verify_rv32_smoke_trace.ps1 `
      -TracePath $tracePath
  }
  Invoke-Checked "Build mixed-width RV32C ELF" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/build_rv32c_smoke_elf.ps1 `
      -OutputPath $compressedElfPath
  }
  Invoke-Checked "DPI RV32C ELF SoC" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_soc_elf_test.ps1 `
      -ElfPath $compressedElfPath -TracePath $compressedTracePath `
      -BuildRoot $SocElfBuildRoot -BuildJobs $BuildJobs `
      -TimeoutCycles $TimeoutCycles
  }
  Invoke-Checked "RV32C architectural trace" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/verify_rv32c_smoke_trace.ps1 `
      -TracePath $compressedTracePath
  }
  Invoke-Checked "Build M/U privilege ELF" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/build_rv32_priv_smoke_elf.ps1 `
      -OutputPath $privElfPath
  }
  Invoke-Checked "DPI M/U privilege ELF SoC" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/run_soc_elf_test.ps1 `
      -ElfPath $privElfPath -TracePath $privTracePath `
      -BuildRoot $SocElfBuildRoot -BuildJobs $BuildJobs `
      -TimeoutCycles $TimeoutCycles
  }
  Invoke-Checked "M/U privilege architectural trace" {
    & $powerShell -ExecutionPolicy Bypass -File scripts/verify_rv32_priv_smoke_trace.ps1 `
      -TracePath $privTracePath
  }
} finally {
  Pop-Location
}

Write-Host "`nFULL DIRECTED VERIFICATION PASS"
Write-Host "ELF   : $elfPath"
Write-Host "Trace : $tracePath"
Write-Host "C ELF : $compressedElfPath"
Write-Host "C trace: $compressedTracePath"
Write-Host "Priv ELF: $privElfPath"
Write-Host "Priv trace: $privTracePath"
