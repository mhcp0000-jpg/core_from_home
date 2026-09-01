param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$GeneratorArguments
)

$ErrorActionPreference = "Stop"
$python = Get-Command python -ErrorAction SilentlyContinue
if (!$python) {
  throw "Python 3 was not found in PATH. Install Python 3 or invoke configure_project.py directly."
}
& $python.Source (Join-Path $PSScriptRoot "configure_project.py") @GeneratorArguments
exit $LASTEXITCODE
