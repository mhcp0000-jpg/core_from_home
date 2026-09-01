param(
  [string]$OutputPath = "C:\rv_build\rv32c_smoke.elf"
)

$ErrorActionPreference = "Stop"

function U-Type([uint32]$imm20, [uint32]$rd, [uint32]$opcode) {
  return [uint32]((($imm20 -band 0xfffff) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor $opcode)
}

function Add-Half(
  [System.Collections.Generic.List[byte]]$Buffer,
  [uint16]$Value
) {
  $Buffer.Add([byte]($Value -band 0xff))
  $Buffer.Add([byte](($Value -shr 8) -band 0xff))
}

function Add-Word(
  [System.Collections.Generic.List[byte]]$Buffer,
  [uint32]$Value
) {
  for ($byte = 0; $byte -lt 4; $byte++) {
    $Buffer.Add([byte](($Value -shr (8 * $byte)) -band 0xff))
  }
}

$program = [System.Collections.Generic.List[byte]]::new()
Add-Word $program (U-Type 0x10000 8 0x37) # 00: lui x8,HostIF
Add-Half $program 0x4495                  # 04: c.li x9,5
Add-Half $program 0x451d                  # 06: c.li x10,7
Add-Half $program 0x94aa                  # 08: c.add x9,x10
Add-Half $program 0x14f9                  # 0a: c.addi x9,-2
Add-Half $program 0x0486                  # 0c: c.slli x9,1
Add-Half $program 0x8085                  # 0e: c.srli x9,1
Add-Word $program (U-Type 0x80020 11 0x37) # 10: lui x11,DTIM
Add-Half $program 0xc184                  # 14: c.sw x9,0(x11)
Add-Half $program 0x4190                  # 16: c.lw x12,0(x11)
Add-Half $program 0x46a9                  # 18: c.li x13,10
Add-Half $program 0x8e15                  # 1a: c.sub x12,x13
Add-Half $program 0xea19                  # 1c: c.bnez x12,+22 -> fail
Add-Half $program 0xc211                  # 1e: c.beqz x12,+4
Add-Half $program 0x4605                  # 20: c.li x12,1 (squashed)
Add-Half $program 0xa011                  # 22: c.j +4
Add-Half $program 0x4609                  # 24: c.li x12,2 (squashed)
Add-Word $program 0x0000000f              # 26: fence
Add-Word $program 0x0000100f              # 2a: fence.i
Add-Half $program 0xc850                  # 2e: c.sw x12,20(x8) -> exit(0)
Add-Half $program 0xa001                  # 30: c.j 0
Add-Half $program 0x4605                  # 32: fail: c.li x12,1
Add-Half $program 0xc850                  # 34: c.sw x12,20(x8) -> exit(1)
Add-Half $program 0xa001                  # 36: c.j 0

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
  $writer.Write([uint16]2)
  $writer.Write([uint16]243)
  $writer.Write([uint32]1)
  $writer.Write($itimBase)
  $writer.Write([uint32]52)
  $writer.Write([uint32]0)
  $writer.Write([uint32]1) # EF_RISCV_RVC
  $writer.Write([uint16]52)
  $writer.Write([uint16]32)
  $writer.Write([uint16]1)
  $writer.Write([uint16]0)
  $writer.Write([uint16]0)
  $writer.Write([uint16]0)

  $programBytes = [uint32]$program.Count
  $writer.Write([uint32]1)
  $writer.Write([uint32]0x100)
  $writer.Write($itimBase)
  $writer.Write($itimBase)
  $writer.Write($programBytes)
  $writer.Write($programBytes)
  $writer.Write([uint32]5)
  $writer.Write([uint32]0x1000)

  while ($stream.Position -lt 0x100) { $writer.Write([byte]0) }
  $writer.Write($program.ToArray())
} finally {
  $writer.Dispose()
  $stream.Dispose()
}

Write-Host "Generated mixed-width RV32IC smoke ELF: $outputFullPath"
