param(
  [Parameter(Mandatory = $true)]
  [string]$TracePath
)

$ErrorActionPreference = "Stop"
$rows = Import-Csv -LiteralPath $TracePath
if (!$rows -or ($rows.Count -eq 0)) { throw "Commit trace is empty." }

$expectedOrder = 0
$lane1Count = 0
$trapCount = 0
$integerWrites = 0
$fpWrites = 0
foreach ($row in $rows) {
  if ([uint64]$row.order -ne $expectedOrder) {
    throw "Non-contiguous retire order at row ${expectedOrder}: $($row.order)"
  }
  $expectedOrder++
  if ([int]$row.lane -eq 1) { $lane1Count++ }
  if ([int]$row.trap -ne 0) { $trapCount++ }
  if ([int]$row.rd_write -ne 0) {
    if ([int]$row.rd_fp -ne 0) { $fpWrites++ } else { $integerWrites++ }
  }
}

Write-Host "Commit trace rows : $($rows.Count)"
Write-Host "Lane-1 commits    : $lane1Count"
Write-Host "Integer writes    : $integerWrites"
Write-Host "FP writes         : $fpWrites"
Write-Host "Trap records      : $trapCount"

if ($lane1Count -eq 0) {
  throw "No lane-1 commit was observed; dual-commit behavior was not exercised."
}
