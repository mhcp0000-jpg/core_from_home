param([string]$BuildRoot='', [string]$Baseline='e9d135b', [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite')
# All-input, two-state proof of the production sticky-shift helper, including
# every signed shift encoding. Negative control must fail for a corrupted bit.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/fpu_sticky_formal'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be below workspace'}
$source=Get-Content "$repo/rtl/backend/rv_fpu.sv" -Raw
$commit=(& git rev-parse --verify "$Baseline^{commit}").Trim()
if($LASTEXITCODE){throw 'Missing immutable reference'}
$reference=(& git show "${commit}:rtl/backend/rv_fpu.sv") -join "`n"
if($LASTEXITCODE){throw 'Cannot read reference'}
$pattern='(?s)function automatic logic \[MAGW-1:0\] right_shift_sticky\(.*?endfunction'
$current=[regex]::Match($source,$pattern);$gold=[regex]::Match($reference,$pattern)
if(!$current.Success -or !$gold.Success){throw 'Missing exact helper'}
$constants=[regex]::Matches($source,'localparam (?:int unsigned (?:MAGW|EXPW)\s*|logic signed \[EXPW-1:0\] MAGW_S)\s*=\s*[^;]+;')
if($constants.Count -ne 3){throw 'Update proof constants explicitly'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$oldPath=$env:PATH
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$oldPath
  @{sourceSha256=(Get-FileHash "$repo/rtl/backend/rv_fpu.sv").Hash;baselineCommit=$commit;
    scope='Exact helper, arbitrary 80-bit magnitude and signed 16-bit shift, two-state; not pipeline/IEEE proof'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($negative in @($false,$true)){
    $name=if($negative){'negative'}else{'positive'}
    $mask=if($negative){" ^ MAGW'(1)"}else{''}
    $fixture=@"
module sticky_miter(input logic [79:0] value_i,input logic signed [15:0] shift_i,
                    output logic mismatch);
  $($constants.Value -join "`n")
  $($current.Value)
  $($gold.Value -replace '\bright_shift_sticky\b','reference_shift')
  assign mismatch=((right_shift_sticky(value_i,shift_i)$mask) != reference_shift(value_i,shift_i));
endmodule
"@
    [IO.File]::WriteAllText("$run/$name.sv",$fixture,[Text.UTF8Encoding]::new($false))
    & "$ToolRoot/bin/yosys.exe" -Q -T -p "read_slang --top sticky_miter $run/$name.sv; prep -top sticky_miter -flatten; opt; sat -verify -prove mismatch 0 -show-inputs" *> "$run/$name.log"
    if($negative){
      if($LASTEXITCODE -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){throw 'Negative control not rejected'}
    }elseif($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)) {throw 'Proof incomplete/failed'}
    Write-Output "PASS $name"
  }
} finally {$env:PATH=$oldPath; & subst "$drive`:" /d | Out-Null}
