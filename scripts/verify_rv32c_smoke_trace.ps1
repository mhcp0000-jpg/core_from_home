param(
  [Parameter(Mandatory = $true)]
  [string]$TracePath
)

$ErrorActionPreference = "Stop"
$rows = @(Import-Csv -LiteralPath $TracePath)
if ($rows.Count -eq 0) { throw "Commit trace is empty." }

$expected = @(
  @("80000000", "10000437", 1, 8,  "10000000"),
  @("80000004", "00004495", 1, 9,  "00000005"),
  @("80000006", "0000451d", 1, 10, "00000007"),
  @("80000008", "000094aa", 1, 9,  "0000000c"),
  @("8000000a", "000014f9", 1, 9,  "0000000a"),
  @("8000000c", "00000486", 1, 9,  "00000014"),
  @("8000000e", "00008085", 1, 9,  "0000000a"),
  @("80000010", "800205b7", 1, 11, "80020000"),
  @("80000014", "0000c184", 0, 0,  "00000000"),
  @("80000016", "00004190", 1, 12, "0000000a"),
  @("80000018", "000046a9", 1, 13, "0000000a"),
  @("8000001a", "00008e15", 1, 12, "00000000"),
  @("8000001c", "0000ea19", 0, 0,  "00000000"),
  @("8000001e", "0000c211", 0, 0,  "00000000"),
  @("80000022", "0000a011", 0, 0,  "00000000"),
  @("80000026", "0000000f", 0, 0,  "00000000"),
  @("8000002a", "0000100f", 0, 0,  "00000000"),
  @("8000002e", "0000c850", 0, 0,  "00000000")
)

$payload = @($rows | Where-Object {
  ([Convert]::ToUInt32($_.pc, 16) -ge [Convert]::ToUInt32("80000000", 16)) -and
  ([Convert]::ToUInt32($_.pc, 16) -le [Convert]::ToUInt32("8000002e", 16))
})
if ($payload.Count -ne $expected.Count) {
  throw "RV32C payload retire count mismatch: got $($payload.Count), expected $($expected.Count)."
}

for ($index = 0; $index -lt $expected.Count; $index++) {
  $row = $payload[$index]
  $want = $expected[$index]
  if (($row.pc.ToLowerInvariant() -ne $want[0]) -or
      ($row.instruction.ToLowerInvariant() -ne $want[1])) {
    throw "RV32C PC/instruction mismatch at index ${index}: got $($row.pc)/$($row.instruction), expected $($want[0])/$($want[1])."
  }
  if (([int]$row.trap -ne 0) -or ([int]$row.rd_fp -ne 0)) {
    throw "Unexpected RV32C trap/FP record at $($row.pc)."
  }
  if ([int]$row.rd_write -ne [int]$want[2]) {
    throw "RV32C destination-valid mismatch at $($row.pc)."
  }
  if ([int]$want[2] -ne 0) {
    if (([int]$row.rd -ne [int]$want[3]) -or
        ($row.wdata.ToLowerInvariant() -ne $want[4])) {
      throw "RV32C write mismatch at $($row.pc): rd=$($row.rd) data=$($row.wdata)."
    }
  }
}

if (@($payload | Where-Object { $_.pc -in @("80000020", "80000024") }).Count -ne 0) {
  throw "A squashed compressed instruction reached commit."
}

$dualCommitCycles = @($payload | Group-Object cycle |
  Where-Object { $_.Count -eq 2 }).Count
if ($dualCommitCycles -eq 0) {
  throw "RV32C payload did not exercise dual commit."
}

Write-Host "RV32IC mixed-width architectural trace PASS"
Write-Host "Payload instructions : $($payload.Count)"
Write-Host "Dual-commit cycles   : $dualCommitCycles"
Write-Host "Squashed PCs absent  : 0x80000020, 0x80000024"
