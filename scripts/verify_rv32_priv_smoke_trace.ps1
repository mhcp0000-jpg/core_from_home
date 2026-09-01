param(
  [Parameter(Mandatory = $true)]
  [string]$TracePath
)

$ErrorActionPreference = "Stop"
$rows = @(Import-Csv -LiteralPath $TracePath)
if ($rows.Count -eq 0) { throw "Commit trace is empty." }

$payload = @($rows | Where-Object {
  ([Convert]::ToUInt32($_.pc, 16) -ge [Convert]::ToUInt32("80000000", 16)) -and
  ([Convert]::ToUInt32($_.pc, 16) -le [Convert]::ToUInt32("80000154", 16))
})
$traps = @($payload | Where-Object { [int]$_.trap -ne 0 })
if ($traps.Count -ne 2) {
  throw "Expected exactly two U-mode traps, observed $($traps.Count)."
}

$expectedTraps = @(
  @("80000084", 2, "340515f3"),
  @("8000008c", 8, "00000073")
)
for ($index = 0; $index -lt $expectedTraps.Count; $index++) {
  $row = $traps[$index]
  $want = $expectedTraps[$index]
  if (($row.pc.ToLowerInvariant() -ne $want[0]) -or
      ([int]$row.cause -ne [int]$want[1]) -or
      ($row.instruction.ToLowerInvariant() -ne $want[2]) -or
      ([int]$row.rd_write -ne 0)) {
    throw "Privilege trap mismatch at index ${index}: pc=$($row.pc) cause=$($row.cause) instruction=$($row.instruction)."
  }
}

foreach ($requiredPc in @("80000040", "80000080", "80000088",
                           "80000100", "80000148", "80000128")) {
  if (!($payload | Where-Object { $_.pc -eq $requiredPc })) {
    throw "Required M/U control-flow PC $requiredPc did not commit."
  }
}

foreach ($forbiddenPc in @("80000090", "8000014c", "80000150")) {
  if ($payload | Where-Object { $_.pc -eq $forbiddenPc }) {
    throw "Failure-path PC $forbiddenPc reached commit."
  }
}

$resumeWrite = @($payload | Where-Object {
  ($_.pc -eq "80000088") -and ([int]$_.rd_write -eq 1) -and
  ([int]$_.rd -eq 12) -and ($_.wdata -eq "00000001")
})
if ($resumeWrite.Count -ne 1) {
  throw "U-mode resume write after illegal CSR trap was not observed."
}

$trapCountWrite = @($payload | Where-Object {
  ($_.pc -eq "80000104") -and ([int]$_.rd_write -eq 1) -and
  ([int]$_.rd -eq 22) -and ($_.wdata -eq "00000002")
})
if ($trapCountWrite.Count -ne 1) {
  throw "Second precise trap count was not observed."
}

Write-Host "RV32 M/U privilege architectural trace PASS"
Write-Host "Expected traps       : illegal CSR=2, ECALL_U=8"
Write-Host "U-mode resume        : PASS"
Write-Host "M-mode HostIF exit   : PASS"
