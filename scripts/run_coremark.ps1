param(
  [ValidateRange(1, 1000000)]
  [int]$Iterations = 2,
  [string]$ToolchainRoot =
    "C:\rv_toolchains\xpack-riscv-none-elf-gcc-15.2.0-1",
  [string]$CoreMarkRoot = "",
  [string]$ArtifactRoot = "C:\rv_build\coremark_rtl",
  [string]$PublishRoot = "",
  [string]$SocElfBuildRoot = "",
  [ValidateRange(1, 32)]
  [int]$BuildJobs = 4,
  [ValidateRange(1, 1000000000)]
  [int]$TimeoutCycles = 50000000
)

$ErrorActionPreference = "Stop"
$coreMarkCommit = "1f483d5b8316753a742cbf5590caf5bd0a4e4777"
$repoRoot = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null

if (!$CoreMarkRoot) { $CoreMarkRoot = Join-Path $ArtifactRoot "upstream-coremark" }
if (!(Test-Path -LiteralPath (Join-Path $CoreMarkRoot "core_main.c"))) {
  & git clone https://github.com/eembc/coremark.git $CoreMarkRoot
  if ($LASTEXITCODE -ne 0) { throw "Unable to clone upstream CoreMark." }
  & git -C $CoreMarkRoot checkout --detach $coreMarkCommit
  if ($LASTEXITCODE -ne 0) { throw "Unable to select pinned CoreMark commit." }
}
$upstreamCommit = (& git -C $CoreMarkRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "CoreMarkRoot is not a Git checkout." }
if ($upstreamCommit -ne $coreMarkCommit) {
  throw "CoreMark source must be pinned to $coreMarkCommit; found $upstreamCommit"
}
if (& git -C $CoreMarkRoot status --porcelain) {
  throw "CoreMarkRoot contains local modifications; use a clean upstream checkout."
}

$bin = Join-Path $ToolchainRoot "bin"
$gcc = Join-Path $bin "riscv-none-elf-gcc.exe"
$objdump = Join-Path $bin "riscv-none-elf-objdump.exe"
$readelf = Join-Path $bin "riscv-none-elf-readelf.exe"
$nm = Join-Path $bin "riscv-none-elf-nm.exe"
$sizeTool = Join-Path $bin "riscv-none-elf-size.exe"
foreach ($tool in @($gcc, $objdump, $readelf, $nm, $sizeTool)) {
  if (!(Test-Path -LiteralPath $tool)) { throw "Required tool not found: $tool" }
}

if (!$SocElfBuildRoot) { $SocElfBuildRoot = Join-Path $ArtifactRoot "soc_elf_build" }
$elfPath = Join-Path $ArtifactRoot "coremark.elf"
$mapPath = Join-Path $ArtifactRoot "coremark.map"
$disassemblyPath = Join-Path $ArtifactRoot "coremark.disasm"
$headersPath = Join-Path $ArtifactRoot "coremark.headers"
$symbolsPath = Join-Path $ArtifactRoot "coremark.symbols"
$simulationLog = Join-Path $ArtifactRoot "coremark.sim.log"
$resultPath = Join-Path $ArtifactRoot "coremark.result.log"
$jsonPath = Join-Path $ArtifactRoot "coremark.result.json"

$portRoot = Join-Path $repoRoot "sw\benchmarks\coremark\port"
$sources = @(
  (Join-Path $repoRoot "sw\benchmarks\coremark\rv32_start.S"),
  (Join-Path $portRoot "core_portme.c"),
  (Join-Path $CoreMarkRoot "core_list_join.c"),
  (Join-Path $CoreMarkRoot "core_main.c"),
  (Join-Path $CoreMarkRoot "core_matrix.c"),
  (Join-Path $CoreMarkRoot "core_state.c"),
  (Join-Path $CoreMarkRoot "core_util.c")
)
$linker = Join-Path $repoRoot "sw\benchmarks\coremark\rv32_tim.ld"
$gccArgs = @(
  "-march=rv32imc_zicsr_zifencei", "-mabi=ilp32", "-mcmodel=medany",
  "-msmall-data-limit=0", "-O2", "-ffreestanding", "-fno-builtin",
  "-fno-common", "-fno-asynchronous-unwind-tables", "-fno-unwind-tables",
  "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra",
  "-I", $portRoot, "-I", $CoreMarkRoot,
  "-DPERFORMANCE_RUN=1", "-DITERATIONS=$Iterations",
  "-DTOTAL_DATA_SIZE=2000", "-DMAIN_HAS_NOARGC=1",
  "-DMEM_METHOD=MEM_STATIC", "-DMULTITHREAD=1"
) + $sources + @(
  "-nostdlib", "-nostartfiles", "-Wl,--gc-sections", "-Wl,--build-id=none",
  "-Wl,-Map,$mapPath", "-T", $linker, "-lgcc", "-o", $elfPath
)
& $gcc @gccArgs
if ($LASTEXITCODE -ne 0) { throw "CoreMark RV32 compilation failed." }

& $objdump -d -S $elfPath | Set-Content -LiteralPath $disassemblyPath
if ($LASTEXITCODE -ne 0) { throw "objdump failed." }
& $readelf -h -l $elfPath | Set-Content -LiteralPath $headersPath
if ($LASTEXITCODE -ne 0) { throw "readelf failed." }
& $nm -n $elfPath | Set-Content -LiteralPath $symbolsPath
if ($LASTEXITCODE -ne 0) { throw "nm failed." }
$sizeLine = (& $sizeTool $elfPath | Select-Object -Last 1)

$runner = Join-Path $PSScriptRoot "run_soc_elf_test.ps1"
$savedErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = "Continue"
  $runnerOutput = & powershell -ExecutionPolicy Bypass -File $runner `
    -ElfPath $elfPath -BuildJobs $BuildJobs -BuildRoot $SocElfBuildRoot `
    -TimeoutCycles $TimeoutCycles 2>&1
  $runnerExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $savedErrorActionPreference
}
$runnerOutput | Tee-Object -LiteralPath $simulationLog
if ($runnerExitCode -ne 0) { throw "CoreMark SoC simulation failed." }

$logText = Get-Content -LiteralPath $simulationLog -Raw
$matches = [regex]::Matches(
  $logText, '\[host-event kind=0 data=0x([0-9a-fA-F]{8})\]')
$values = @($matches | ForEach-Object {
  [Convert]::ToUInt32($_.Groups[1].Value, 16)
})
$magicIndex = [Array]::IndexOf($values, [uint32]0x434d0001)
if ($magicIndex -lt 0 -or ($values.Count - $magicIndex) -lt 12) {
  throw "Complete CoreMark HostIF result packet was not observed."
}
$packet = $values[$magicIndex..($magicIndex + 11)]
$cycles = [uint64]$packet[2] + [uint64]$packet[3] * [uint64]4294967296
$instructions = [uint64]$packet[4] + [uint64]$packet[5] * [uint64]4294967296
$status = [uint32]$packet[11]
if (($status -band 0x17u) -ne 0x01u) {
  throw ("CoreMark validation failed; status=0x{0:x8}" -f $status)
}
if ($packet[6] -ne 0xe9f5 -or $packet[7] -ne 0xe714 -or
    $packet[8] -ne 0x1fd7 -or $packet[9] -ne 0x8e3a) {
  throw "CoreMark reported unexpected 2K performance CRC values."
}
if ($packet[1] -ne $Iterations) {
  throw "CoreMark iteration telemetry does not match the requested count."
}

$cyclesPerIteration = [double]$cycles / $Iterations
$instructionsPerIteration = [double]$instructions / $Iterations
$ipc = if ($cycles) { [double]$instructions / [double]$cycles } else { 0.0 }
$coreMarkPerMHz = if ($cycles) {
  [double]$Iterations * 1000000.0 / [double]$cycles
} else { 0.0 }
$durationRule = if (($status -band 0x08u) -ne 0) { "NOT MET (expected for short RTL run)" } else { "met" }

$summary = @(
  "COREMARK SHORT RTL RUN PASS",
  "Classification        : non-certified implementation estimate",
  "Upstream commit       : $upstreamCommit",
  "Toolchain             : xPack RISC-V GCC 15.2.0-1",
  "ISA / ABI             : rv32imc_zicsr_zifencei / ilp32",
  "Compiler optimization : -O2",
  "Memory                : 128 KiB ITIM + 128 KiB DTIM, 1:1 local",
  "Iterations            : $Iterations",
  "Cycles                : $cycles",
  ("Cycles / iteration    : {0:N3}" -f $cyclesPerIteration),
  "Retired instructions  : $instructions",
  ("Instructions / iter.   : {0:N3}" -f $instructionsPerIteration),
  ("IPC                   : {0:N6}" -f $ipc),
  ("Estimated CoreMark/MHz: {0:N6}" -f $coreMarkPerMHz),
  ("seedcrc / list        : 0x{0:x4} / 0x{1:x4}" -f $packet[6], $packet[7]),
  ("matrix / state        : 0x{0:x4} / 0x{1:x4}" -f $packet[8], $packet[9]),
  ("final CRC             : 0x{0:x4}" -f $packet[10]),
  ("Status word           : 0x{0:x8}" -f $status),
  "Official 10-second rule: $durationRule",
  "ELF size              : $sizeLine"
)
$summary | Tee-Object -LiteralPath $resultPath

[ordered]@{
  classification = "non-certified implementation estimate"
  upstream_commit = $upstreamCommit
  iterations = $Iterations
  cycles = $cycles
  retired_instructions = $instructions
  cycles_per_iteration = $cyclesPerIteration
  instructions_per_iteration = $instructionsPerIteration
  ipc = $ipc
  estimated_coremark_per_mhz = $coreMarkPerMHz
  seedcrc = ("0x{0:x4}" -f $packet[6])
  crclist = ("0x{0:x4}" -f $packet[7])
  crcmatrix = ("0x{0:x4}" -f $packet[8])
  crcstate = ("0x{0:x4}" -f $packet[9])
  crcfinal = ("0x{0:x4}" -f $packet[10])
  status = ("0x{0:x8}" -f $status)
  official_ten_second_rule_met = (($status -band 0x08u) -eq 0)
} | ConvertTo-Json | Set-Content -LiteralPath $jsonPath

if ($PublishRoot) {
  New-Item -ItemType Directory -Force -Path $PublishRoot | Out-Null
  foreach ($artifact in @($disassemblyPath, $headersPath, $symbolsPath,
                           $simulationLog, $resultPath, $jsonPath)) {
    Copy-Item -LiteralPath $artifact -Destination $PublishRoot -Force
  }
}
