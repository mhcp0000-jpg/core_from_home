param(
  [string]$ArtifactRoot = "C:\rv_build\verification",
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4,
  [ValidateRange(1, 1000000000)]
  [int]$TimeoutCycles = 20000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$elfPath = Join-Path $ArtifactRoot "rv32_smoke.elf"
$tracePath = Join-Path $ArtifactRoot "rv32_smoke_commit.csv"

function Invoke-Checked([string]$name, [scriptblock]$command) {
  Write-Host "`n=== $name ==="
  & $command
  if ($LASTEXITCODE -ne 0) { throw "$name failed with exit code $LASTEXITCODE." }
}

Push-Location $repoRoot
try {
  Invoke-Checked "RTL parse/elaboration" { python scripts/check_rtl.py }
  Invoke-Checked "Unit regression" {
    powershell -ExecutionPolicy Bypass -File scripts/run_unit_tests.ps1
  }
  Invoke-Checked "Backend integration" {
    powershell -ExecutionPolicy Bypass -File scripts/run_integration_tests.ps1
  }
  Invoke-Checked "Directed SoC boot" {
    powershell -ExecutionPolicy Bypass -File scripts/run_soc_boot_test.ps1
  }
  Invoke-Checked "Build self-check ELF" {
    powershell -ExecutionPolicy Bypass -File scripts/build_rv32_smoke_elf.ps1 `
      -OutputPath $elfPath
  }
  Invoke-Checked "DPI ELF SoC" {
    powershell -ExecutionPolicy Bypass -File scripts/run_soc_elf_test.ps1 `
      -ElfPath $elfPath -TracePath $tracePath -BuildJobs $BuildJobs `
      -TimeoutCycles $TimeoutCycles
  }
  Invoke-Checked "Commit trace invariants" {
    powershell -ExecutionPolicy Bypass -File scripts/analyze_commit_trace.ps1 `
      -TracePath $tracePath
  }
  Invoke-Checked "RV32IMF architectural trace" {
    powershell -ExecutionPolicy Bypass -File scripts/verify_rv32_smoke_trace.ps1 `
      -TracePath $tracePath
  }
} finally {
  Pop-Location
}

Write-Host "`nFULL DIRECTED VERIFICATION PASS"
Write-Host "ELF   : $elfPath"
Write-Host "Trace : $tracePath"
