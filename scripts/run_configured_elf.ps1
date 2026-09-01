param(
  [string]$ElfPath = "",
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot "config\soc_project.json"
if (!(Test-Path -LiteralPath $configPath)) {
  throw "Generated configuration was not found: $configPath"
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (!$ElfPath) { $ElfPath = [string]$config.host.default_elf }
if (!$ElfPath) {
  throw "No default ELF is configured. Pass -ElfPath <file>."
}
if (![System.IO.Path]::IsPathRooted($ElfPath)) {
  $ElfPath = Join-Path $repoRoot $ElfPath
}
$artifactRoot = [string]$config.host.artifact_root
if (![System.IO.Path]::IsPathRooted($artifactRoot)) {
  $artifactRoot = Join-Path $repoRoot $artifactRoot
}
$runner = Join-Path $PSScriptRoot "run_soc_elf_test.ps1"
Push-Location $repoRoot
try {
  & powershell -ExecutionPolicy Bypass -File $runner `
    -ElfPath $ElfPath `
    -VerilatorRoot $VerilatorRoot `
    -W64DevkitRoot $W64DevkitRoot `
    -BuildRoot (Join-Path $artifactRoot "build") `
    -TracePath (Join-Path $artifactRoot "commit.csv") `
    -BuildJobs $BuildJobs `
    -TimeoutCycles ([int]$config.host.timeout_cycles)
  $runnerExitCode = $LASTEXITCODE
} finally {
  Pop-Location
}
exit $runnerExitCode
