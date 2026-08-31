param(
  [Parameter(Mandatory = $true)]
  [string]$ElfPath,
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [string]$BuildRoot = "C:\rv_build\soc_elf"
)

$ErrorActionPreference = "Stop"

$resolvedElf = (Resolve-Path -LiteralPath $ElfPath).Path
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

$sources = Get-Content -LiteralPath (Join-Path $repoRoot "rtl\filelist.f") |
  Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") }
$sources += "tb/dpi/rv_host_dpi.sv"
$sources += "tb/dpi/rv_soc_dpi_tb.sv"
$sources += "tb/dpi/elf_loader.cpp"
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$stagedElf = Join-Path $BuildRoot "payload.elf"
Copy-Item -LiteralPath $resolvedElf -Destination $stagedElf -Force

try {
  & subst $drive $repoRoot
  if ($LASTEXITCODE -ne 0) { throw "Failed to map $repoRoot to $drive." }
  $mappedRoot = "$drive\"
  $mappedSources = $sources | ForEach-Object { Join-Path $mappedRoot $_ }
  $oldVerilatorRoot = $env:VERILATOR_ROOT
  try {
    $env:VERILATOR_ROOT = $VerilatorRoot
    & $verilator --cc --exe --timing --main -DSYNTHESIS -Wno-fatal `
      --top-module rv_soc_dpi_tb --Mdir $BuildRoot @mappedSources
    if ($LASTEXITCODE -ne 0) { throw "DPI SoC code generation failed." }
  } finally {
    $env:VERILATOR_ROOT = $oldVerilatorRoot
  }

  $oldPath = $env:PATH
  try {
    $env:PATH = (Join-Path $W64DevkitRoot "bin") + ";" + $oldPath
    & $make -C $BuildRoot -f Vrv_soc_dpi_tb.mk CXX=g++ CC=gcc LINK=g++
    if ($LASTEXITCODE -ne 0) { throw "DPI SoC C++ build failed." }
  } finally {
    $env:PATH = $oldPath
  }

  $simulation = Join-Path $BuildRoot "Vrv_soc_dpi_tb.exe"
  & $simulation "+elf=$stagedElf"
  if ($LASTEXITCODE -ne 0) { throw "DPI ELF SoC simulation failed." }
} finally {
  if ($drive) { & subst $drive /d | Out-Null }
}
