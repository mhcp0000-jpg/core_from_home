param(
  [string]$ToolchainRoot =
    "C:\rv_toolchains\xpack-riscv-none-elf-gcc-15.2.0-1",
  [string]$ArtifactRoot = "C:\rv_build\c_loop_smoke",
  [string]$PublishRoot = "",
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4,
  [ValidateRange(1, 1000000000)]
  [int]$TimeoutCycles = 100000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$gcc = Join-Path $ToolchainRoot "bin\riscv-none-elf-gcc.exe"
$objdump = Join-Path $ToolchainRoot "bin\riscv-none-elf-objdump.exe"
$readelf = Join-Path $ToolchainRoot "bin\riscv-none-elf-readelf.exe"
$nm = Join-Path $ToolchainRoot "bin\riscv-none-elf-nm.exe"
foreach ($tool in @($gcc, $objdump, $readelf, $nm)) {
  if (!(Test-Path -LiteralPath $tool)) { throw "Required tool not found: $tool" }
}

New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
$elfPath = Join-Path $ArtifactRoot "rv32_loop_smoke.elf"
$tracePath = Join-Path $ArtifactRoot "rv32_loop_smoke_commit.csv"
$mapPath = Join-Path $ArtifactRoot "rv32_loop_smoke.map"
$disassemblyPath = Join-Path $ArtifactRoot "rv32_loop_smoke.disasm"
$headersPath = Join-Path $ArtifactRoot "rv32_loop_smoke.headers"
$symbolsPath = Join-Path $ArtifactRoot "rv32_loop_smoke.symbols"
$simulationLog = Join-Path $ArtifactRoot "rv32_loop_smoke.sim.log"

$startup = Join-Path $repoRoot "sw\smoke\rv32_start.S"
$source = Join-Path $repoRoot "sw\smoke\rv32_loop_smoke.c"
$linker = Join-Path $repoRoot "sw\smoke\rv32_tim.ld"

& $gcc -march=rv32imfc_zicsr_zifencei -mabi=ilp32f -mcmodel=medany `
  -msmall-data-limit=0 -O1 -fno-unroll-loops -ffreestanding -fno-builtin `
  -fno-common -fno-asynchronous-unwind-tables -fno-unwind-tables `
  -ffunction-sections -fdata-sections -nostdlib -nostartfiles `
  "-Wl,-T,$linker" "-Wl,-Map,$mapPath" "-Wl,--gc-sections" `
  "-Wl,--build-id=none" -o $elfPath $startup $source -lgcc
if ($LASTEXITCODE -ne 0) { throw "RV32 C compilation failed." }

& $objdump -d -S $elfPath | Set-Content -LiteralPath $disassemblyPath
if ($LASTEXITCODE -ne 0) { throw "objdump failed." }
& $readelf -h -l $elfPath | Set-Content -LiteralPath $headersPath
if ($LASTEXITCODE -ne 0) { throw "readelf failed." }
& $nm -n $elfPath | Set-Content -LiteralPath $symbolsPath
if ($LASTEXITCODE -ne 0) { throw "nm failed." }

$runner = Join-Path $PSScriptRoot "run_soc_elf_test.ps1"
$savedErrorActionPreference = $ErrorActionPreference
try {
  # Native compiler warnings arrive on stderr; preserve them in the log and
  # decide pass/fail from the child PowerShell process exit code.
  $ErrorActionPreference = "Continue"
  $runnerOutput = & powershell -ExecutionPolicy Bypass -File $runner `
    -ElfPath $elfPath -TracePath $tracePath -BuildJobs $BuildJobs `
    -TimeoutCycles $TimeoutCycles 2>&1
  $runnerExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $savedErrorActionPreference
}
$runnerOutput | Tee-Object -LiteralPath $simulationLog
if ($runnerExitCode -ne 0) { throw "C loop SoC simulation failed." }

$logText = Get-Content -LiteralPath $simulationLog -Raw
if ($logText -notmatch '\[host-event kind=0 data=0x009e00b9\]') {
  throw "Expected integer/FP signature 0x009e00b9 was not observed."
}
if ($logText -notmatch '\[host-finish code=0\]') {
  throw "C loop program did not report exit(0)."
}

$rows = @(Import-Csv -LiteralPath $tracePath)
$itimBase = [Convert]::ToUInt32("80000000", 16)
$payload = @($rows | Where-Object {
  [Convert]::ToUInt32($_.pc, 16) -ge $itimBase
})
if ($payload.Count -eq 0) { throw "No ITIM payload instruction retired." }
if (@($payload | Where-Object { $_.trap -ne "0" }).Count -ne 0) {
  throw "Unexpected payload trap in C loop program."
}
if (@($payload | Where-Object { $_.rd_fp -eq "1" }).Count -eq 0) {
  throw "C loop program retired no FP register writes."
}
if (@($payload | Where-Object { $_.lane -eq "1" }).Count -eq 0) {
  throw "C loop program demonstrated no dual commit."
}

$summary = @(
  "C LOOP ELF VERIFICATION PASS",
  "Toolchain            : xPack RISC-V GCC 15.2.0-1",
  "ISA / ABI            : rv32imfc_zicsr_zifencei / ilp32f",
  "Integer output       : 8, 1, 26, 21, 0, 41, 40, 21",
  "Integer sum          : 158",
  "FP output            : 8.75, 2.5, 28.25, 24.0, 3.75, 45.5, 45.25, 27.0",
  "FP sum               : 185.0f (0x43390000)",
  "Observed host event  : 0x009e00b9",
  "Observed host exit   : 0",
  "Payload commits      : $($payload.Count)",
  "FP register commits  : $(@($payload | Where-Object { $_.rd_fp -eq '1' }).Count)",
  "Lane-1 commits       : $(@($payload | Where-Object { $_.lane -eq '1' }).Count)",
  "Payload traps        : 0"
)
$summary | ForEach-Object { Write-Host $_ }
$resultPath = Join-Path $ArtifactRoot "rv32_loop_smoke.result.log"
$summary | Set-Content -LiteralPath $resultPath

if ($PublishRoot) {
  New-Item -ItemType Directory -Force -Path $PublishRoot | Out-Null
  foreach ($artifact in @($tracePath, $disassemblyPath, $headersPath,
                           $symbolsPath, $resultPath)) {
    Copy-Item -LiteralPath $artifact -Destination $PublishRoot -Force
  }
}
