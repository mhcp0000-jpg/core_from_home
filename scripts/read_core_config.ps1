param(
  [Parameter(Mandatory=$true)][string]$PackagePath
)
$ErrorActionPreference='Stop'
$text=Get-Content -LiteralPath $PackagePath -Raw
$text=[regex]::Replace($text,'(?s)/\*.*?\*/|//[^\r\n]*','')
$names=@('AGU_LOAD_BYPASS','EARLY_LOAD_SELECT','COMPATIBLE_PAIR_SELECT',
         'BRANCH_TAG_PIPELINE','DIV_TAG_PIPELINE','BR_CHECKPOINTS')
# Include every additional declared CORE_CFG default in the manifest/banner.
# A new PKG hardware option must never become an unreported local setting.
$declared=[regex]::Matches($text,'\blocalparam\s+(?:bit|int\s+unsigned)\s+CORE_CFG_([A-Z][A-Z0-9_]*)\s*=') |
  ForEach-Object {$_.Groups[1].Value}
foreach($name in $declared) {if($name -notin $names){$names+=$name}}
$values=[ordered]@{}
foreach($name in $names) {
    $pattern=if($text -match ('\blocalparam\s+int\s+unsigned\s+CORE_CFG_'+$name+'\s*=')) {
      '\blocalparam\s+int\s+unsigned\s+CORE_CFG_'+$name+'\s*=\s*([0-9]+)\s*;'
    } else {
      "\blocalparam\s+bit\s+CORE_CFG_"+$name+"\s*=\s*1'b([01])\s*;"
    }
    $matches=[regex]::Matches($text,$pattern)
    if($matches.Count -ne 1){throw "Expected exactly one literal CORE_CFG_$name in $PackagePath; no silent fallback"}
    $values[$name]=[int]$matches[0].Groups[1].Value
}
if($values.BR_CHECKPOINTS -lt 2 -or $values.BR_CHECKPOINTS -gt 32){throw 'CORE_CFG_BR_CHECKPOINTS must be 2..32'}
[pscustomobject]$values
