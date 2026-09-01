param(
  [string]$OutputPath = "C:\rv_build\rv32_priv_smoke.elf"
)

$ErrorActionPreference = "Stop"

function U-Type([uint32]$imm20, [uint32]$rd, [uint32]$opcode) {
  return [uint32]((($imm20 -band 0xfffff) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor $opcode)
}

function I-Type([int32]$imm, [uint32]$rs1, [uint32]$funct3,
                [uint32]$rd, [uint32]$opcode) {
  $encodedImm = [uint32]($imm -band 0xfff)
  return [uint32](($encodedImm -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor $opcode)
}

function S-Type([int32]$imm, [uint32]$rs2, [uint32]$rs1,
                [uint32]$funct3) {
  $encodedImm = [uint32]($imm -band 0xfff)
  return [uint32](((($encodedImm -shr 5) -band 0x7f) -shl 25) -bor
                  (($rs2 -band 0x1f) -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  (($encodedImm -band 0x1f) -shl 7) -bor 0x23)
}

function B-Type([int32]$offset, [uint32]$rs2, [uint32]$rs1,
                [uint32]$funct3) {
  $imm = [uint32]$offset -band 0x1fff
  return [uint32](((($imm -shr 12) -band 1) -shl 31) -bor
                  ((($imm -shr 5) -band 0x3f) -shl 25) -bor
                  (($rs2 -band 0x1f) -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  ((($imm -shr 1) -band 0xf) -shl 8) -bor
                  ((($imm -shr 11) -band 1) -shl 7) -bor 0x63)
}

function CSR-Type([uint32]$csr, [uint32]$rs1, [uint32]$funct3,
                  [uint32]$rd) {
  return [uint32]((($csr -band 0xfff) -shl 20) -bor
                  (($rs1 -band 0x1f) -shl 15) -bor
                  (($funct3 -band 7) -shl 12) -bor
                  (($rd -band 0x1f) -shl 7) -bor 0x73)
}

$instructions = [System.Collections.Generic.List[uint32]]::new()
function Emit([uint32]$instruction) { $instructions.Add($instruction) }
function Pad-To([uint32]$address) {
  while (($instructions.Count * 4) -lt $address) { Emit 0x00000013 }
  if (($instructions.Count * 4) -ne $address) {
    throw "Program layout did not align to 0x$($address.ToString('x'))."
  }
}

Emit (U-Type 0x10000 8 0x37)             # HostIF base
Emit (U-Type 0x00200 7 0x37)             # CLINT base
Emit (S-Type 0 0 7 2)                    # clear MSIP
Emit 0x0000000f                           # fence: wait for clear visibility
Emit (I-Type 31 0 0 9 0x13)              # PMP0 R/W/X NAPOT
Emit (CSR-Type 0x3a0 9 1 0)              # csrw pmpcfg0,x9
Emit (I-Type -1 0 0 9 0x13)
Emit (CSR-Type 0x3b0 9 1 0)              # csrw pmpaddr0,x9
Emit (U-Type 0x80000 5 0x37)
Emit (I-Type 0x100 5 0 5 0x13)           # x5 = M trap handler
Emit (CSR-Type 0x305 5 1 0)              # csrw mtvec,x5
Emit (U-Type 0x80000 6 0x37)
Emit (I-Type 0x080 6 0 6 0x13)           # x6 = U entry
Emit (CSR-Type 0x341 6 1 0)              # csrw mepc,x6
Emit (CSR-Type 0x300 0 1 0)              # MPP=U, interrupts disabled
Emit (I-Type 0 0 0 22 0x13)              # trap count
Emit 0x30200073                           # mret -> U

Pad-To 0x80
Emit (I-Type 5 0 0 10 0x13)              # U: x10=5
Emit (CSR-Type 0x340 10 1 11)            # illegal U access to mscratch
Emit (I-Type 1 0 0 12 0x13)              # must resume here
Emit 0x00000073                           # ecall from U
Emit 0x00000073                           # unexpected return -> third trap/fail

Pad-To 0x100
Emit (CSR-Type 0x342 0 2 20)             # M handler: csrr x20,mcause
Emit (I-Type 1 22 0 22 0x13)             # trap count++
Emit (I-Type 1 0 0 21 0x13)
Emit (B-Type 40 21 22 0)                 # first trap path
Emit (I-Type 2 0 0 21 0x13)
Emit (B-Type 56 21 22 1)                 # count must be 2
Emit (I-Type 8 0 0 21 0x13)
Emit (B-Type 48 21 20 1)                 # second cause must be ECALL_U
Emit (I-Type 1 0 0 21 0x13)
Emit (B-Type 40 21 12 1)                 # resumed U instruction observed
Emit (S-Type 0x14 0 8 2)                 # exit(0) in M mode
Emit 0x0000006f
Emit 0x00000013

Emit (I-Type 2 0 0 21 0x13)              # first trap: cause=illegal
Emit (B-Type 20 21 20 1)
Emit (CSR-Type 0x341 0 2 21)             # read mepc
Emit (I-Type 4 21 0 21 0x13)
Emit (CSR-Type 0x341 21 1 0)             # skip illegal CSR
Emit 0x30200073                           # return to U

Emit (I-Type 1 0 0 21 0x13)              # fail in M mode
Emit (S-Type 0x14 21 8 2)                # exit(1)
Emit 0x0000006f

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
  $writer.Write([uint32]0)
  $writer.Write([uint16]52)
  $writer.Write([uint16]32)
  $writer.Write([uint16]1)
  $writer.Write([uint16]0)
  $writer.Write([uint16]0)
  $writer.Write([uint16]0)

  $programBytes = [uint32]($instructions.Count * 4)
  $writer.Write([uint32]1)
  $writer.Write([uint32]0x100)
  $writer.Write($itimBase)
  $writer.Write($itimBase)
  $writer.Write($programBytes)
  $writer.Write($programBytes)
  $writer.Write([uint32]5)
  $writer.Write([uint32]0x1000)
  while ($stream.Position -lt 0x100) { $writer.Write([byte]0) }
  foreach ($instruction in $instructions) { $writer.Write($instruction) }
} finally {
  $writer.Dispose()
  $stream.Dispose()
}

Write-Host "Generated RV32 M/U privilege smoke ELF: $outputFullPath"
