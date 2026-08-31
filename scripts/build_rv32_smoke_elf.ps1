param(
  [string]$OutputPath = "C:\rv_build\rv32_smoke.elf"
)

$ErrorActionPreference = "Stop"

function U-Type([uint32]$imm20, [uint32]$rd, [uint32]$opcode) {
  return [uint32]((($imm20 -band 0xfffff) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor $opcode)
}

function I-Type([int32]$imm, [uint32]$rs1, [uint32]$funct3,
                [uint32]$rd, [uint32]$opcode) {
  $encodedImm = [uint32]$imm -band 0xfff
  return [uint32](($encodedImm -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor $opcode)
}

function R-Type([uint32]$funct7, [uint32]$rs2, [uint32]$rs1,
                [uint32]$funct3, [uint32]$rd, [uint32]$opcode) {
  return [uint32]((($funct7 -band 0x7f) -shl 25) -bor
                  (($rs2 -band 0x1f) -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor $opcode)
}

function S-Type([int32]$imm, [uint32]$rs2, [uint32]$rs1,
                [uint32]$funct3, [uint32]$opcode) {
  $encodedImm = [uint32]$imm -band 0xfff
  return [uint32](((($encodedImm -shr 5) -band 0x7f) -shl 25) -bor
                  (($rs2 -band 0x1f) -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  (($encodedImm -band 0x1f) -shl 7) -bor $opcode)
}

function B-Type([int32]$offset, [uint32]$rs2, [uint32]$rs1,
                [uint32]$funct3) {
  if (($offset -band 1) -ne 0) { throw "Branch offset must be even" }
  $imm = [uint32]$offset -band 0x1fff
  return [uint32](((($imm -shr 12) -band 1) -shl 31) -bor
                  ((($imm -shr 5) -band 0x3f) -shl 25) -bor
                  (($rs2 -band 0x1f) -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  ((($imm -shr 1) -band 0xf) -shl 8) -bor
                  ((($imm -shr 11) -band 1) -shl 7) -bor 0x63)
}

$instructions = [System.Collections.Generic.List[uint32]]::new()
$instructions.Add((U-Type 0x10000 16 0x37))              # x16 = HostIF base
$instructions.Add((U-Type 0x80020 1 0x37))               # x1 = DTIM base
$instructions.Add((I-Type 5 0 0 2 0x13))                 # x2 = 5
$instructions.Add((I-Type 7 0 0 3 0x13))                 # x3 = 7
$instructions.Add((R-Type 1 3 2 0 4 0x33))               # x4 = 5 * 7
$instructions.Add((S-Type 0 4 1 2 0x23))                 # [DTIM] = 35
$instructions.Add((I-Type 0 1 2 5 0x03))                 # x5 = [DTIM]
$instructions.Add((R-Type 0 3 5 0 6 0x33))               # x6 = 42
$instructions.Add((I-Type 42 0 0 7 0x13))                # x7 = 42
$instructions.Add((B-Type 64 7 6 1))                     # bne -> fail
$instructions.Add((R-Type 1 2 6 4 8 0x33))               # x8 = 42 / 5
$instructions.Add((R-Type 1 2 6 6 9 0x33))               # x9 = 42 % 5
$instructions.Add((R-Type 0 9 8 0 10 0x33))              # x10 = 10
$instructions.Add((I-Type 10 0 0 11 0x13))               # x11 = 10
$instructions.Add((B-Type 44 11 10 1))                   # bne -> fail
$instructions.Add((U-Type 0x3f800 12 0x37))              # IEEE 1.0f
$instructions.Add((R-Type 0x78 0 12 0 1 0x53))           # fmv.w.x f1,x12
$instructions.Add((U-Type 0x40000 13 0x37))              # IEEE 2.0f
$instructions.Add((R-Type 0x78 0 13 0 2 0x53))           # fmv.w.x f2,x13
$instructions.Add((R-Type 0 2 1 0 3 0x53))               # fadd.s f3,f1,f2
$instructions.Add((R-Type 0x70 0 3 0 14 0x53))           # fmv.x.w x14,f3
$instructions.Add((U-Type 0x40400 15 0x37))              # IEEE 3.0f
$instructions.Add((B-Type 12 15 14 1))                   # bne -> fail
$instructions.Add((S-Type 0x14 0 16 2 0x23))             # exit(0)
$instructions.Add(0x0000006f)                            # loop if host stalls
$instructions.Add((I-Type 1 0 0 17 0x13))                # fail: x17 = 1
$instructions.Add((S-Type 0x14 17 16 2 0x23))            # exit(1)
$instructions.Add(0x0000006f)

$itimBase = [Convert]::ToUInt32("80000000", 16)
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
if ($outputDirectory) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$stream = [System.IO.File]::Open(
  $outputFullPath, [System.IO.FileMode]::Create,
  [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
$writer = [System.IO.BinaryWriter]::new($stream)
try {
  $writer.Write([byte[]](0x7f, 0x45, 0x4c, 0x46, 1, 1, 1, 0,
                        0, 0, 0, 0, 0, 0, 0, 0))
  $writer.Write([uint16]2)                  # ET_EXEC
  $writer.Write([uint16]243)                # EM_RISCV
  $writer.Write([uint32]1)
  $writer.Write($itimBase)                  # entry
  $writer.Write([uint32]52)                 # program header offset
  $writer.Write([uint32]0)                  # no section table
  $writer.Write([uint32]0)                  # flags
  $writer.Write([uint16]52)
  $writer.Write([uint16]32)
  $writer.Write([uint16]1)
  $writer.Write([uint16]0)
  $writer.Write([uint16]0)
  $writer.Write([uint16]0)

  $programBytes = [uint32]($instructions.Count * 4)
  $writer.Write([uint32]1)                  # PT_LOAD
  $writer.Write([uint32]0x100)
  $writer.Write($itimBase)
  $writer.Write($itimBase)
  $writer.Write($programBytes)
  $writer.Write($programBytes)
  $writer.Write([uint32]5)                  # PF_R | PF_X
  $writer.Write([uint32]0x1000)

  while ($stream.Position -lt 0x100) { $writer.Write([byte]0) }
  foreach ($instruction in $instructions) { $writer.Write($instruction) }
} finally {
  $writer.Dispose()
  $stream.Dispose()
}

Write-Host "Generated RV32IMF smoke ELF: $outputFullPath"
