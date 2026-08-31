param(
  [Parameter(Mandatory = $true)]
  [string]$TracePath
)

$ErrorActionPreference = "Stop"
$rows = @(Import-Csv -LiteralPath $TracePath)
if ($rows.Count -eq 0) { throw "Commit trace is empty." }

$expected = @(
  @("80000000", "10000837", 1, 0, 16, "10000000"),
  @("80000004", "800200b7", 1, 0,  1, "80020000"),
  @("80000008", "00500113", 1, 0,  2, "00000005"),
  @("8000000c", "00700193", 1, 0,  3, "00000007"),
  @("80000010", "02310233", 1, 0,  4, "00000023"),
  @("80000014", "0040a023", 0, 0,  0, "00000000"),
  @("80000018", "0000a283", 1, 0,  5, "00000023"),
  @("8000001c", "00328333", 1, 0,  6, "0000002a"),
  @("80000020", "02a00393", 1, 0,  7, "0000002a"),
  @("80000024", "04731063", 0, 0,  0, "00000000"),
  @("80000028", "02234433", 1, 0,  8, "00000008"),
  @("8000002c", "022364b3", 1, 0,  9, "00000002"),
  @("80000030", "00940533", 1, 0, 10, "0000000a"),
  @("80000034", "00a00593", 1, 0, 11, "0000000a"),
  @("80000038", "02b51663", 0, 0,  0, "00000000"),
  @("8000003c", "3f800637", 1, 0, 12, "3f800000"),
  @("80000040", "f00600d3", 1, 1,  1, "3f800000"),
  @("80000044", "400006b7", 1, 0, 13, "40000000"),
  @("80000048", "f0068153", 1, 1,  2, "40000000"),
  @("8000004c", "002081d3", 1, 1,  3, "40400000"),
  @("80000050", "e0018753", 1, 0, 14, "40400000"),
  @("80000054", "404007b7", 1, 0, 15, "40400000"),
  @("80000058", "00f71663", 0, 0,  0, "00000000"),
  @("8000005c", "00082a23", 0, 0,  0, "00000000")
)

$payload = @($rows | Where-Object {
  ([Convert]::ToUInt32($_.pc, 16) -ge [Convert]::ToUInt32("80000000", 16)) -and
  ([Convert]::ToUInt32($_.pc, 16) -le [Convert]::ToUInt32("8000005c", 16))
})
if ($payload.Count -ne $expected.Count) {
  throw "Payload retire count mismatch: got $($payload.Count), expected $($expected.Count)."
}

for ($index = 0; $index -lt $expected.Count; $index++) {
  $row = $payload[$index]
  $want = $expected[$index]
  if (($row.pc.ToLowerInvariant() -ne $want[0]) -or
      ($row.instruction.ToLowerInvariant() -ne $want[1])) {
    throw "PC/instruction mismatch at payload index ${index}: got $($row.pc)/$($row.instruction), expected $($want[0])/$($want[1])."
  }
  if ([int]$row.trap -ne 0) {
    throw "Unexpected payload trap at $($row.pc), cause=$($row.cause), tval=$($row.tval)."
  }
  if (([int]$row.rd_write -ne [int]$want[2]) -or
      ([int]$row.rd_fp -ne [int]$want[3])) {
    throw "Destination write-class mismatch at $($row.pc)."
  }
  if ([int]$want[2] -ne 0) {
    if (([int]$row.rd -ne [int]$want[4]) -or
        ($row.wdata.ToLowerInvariant() -ne $want[5])) {
      throw "Architectural write mismatch at $($row.pc): rd=$($row.rd) data=$($row.wdata)."
    }
  }
}

$payloadCycles = $payload | Group-Object cycle
$dualCommitCycles = @($payloadCycles | Where-Object { $_.Count -eq 2 }).Count
if ($dualCommitCycles -eq 0) {
  throw "Smoke payload did not exercise dual commit."
}

Write-Host "RV32IMF smoke architectural trace PASS"
Write-Host "Payload instructions : $($payload.Count)"
Write-Host "Dual-commit cycles   : $dualCommitCycles"
Write-Host "Checked INT writes   : 16"
Write-Host "Checked FP writes    : 3"
