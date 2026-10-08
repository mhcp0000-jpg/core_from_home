param([string]$BuildRoot='', [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite')
# Exact production age-tree equations. Arbitrary older/ready sets, including
# impossible age matrices; not a proof of the entire clocked IQ state machine.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/iq_age_tree_formal'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be below workspace'}
$source=Get-Content "$repo/rtl/backend/rv_issue_queue.sv" -Raw
$emptyEncoding=$source.Contains('assign age_one[age_e][0]')
$leafPattern=if($emptyEncoding){'(?s)assign age_one\[age_e\]\[0\].*?assign age_empty\[age_e\]\[0\].*?;'}
  else{'(?s)assign age_any\[age_e\]\[0\].*?assign age_ge2\[age_e\]\[0\].*?;'}
$leaf=[regex]::Match($source,$leafPattern)
$tree=[regex]::Match($source,"(?s)for \(genvar age_l = 0;.*?\r?\n      end\r?\n      assign am_first")
if(!$leaf.Success -or !$tree.Success){throw 'Production tree shape changed; update extractor'}
$body=($leaf.Value+"`n"+($tree.Value -replace '\s*assign am_first$','')) -replace '\[age_e\]',''
$declarations=if($emptyEncoding){'age_empty [0:AGE_LEVELS], age_one [0:AGE_LEVELS]'}else{'age_any [0:AGE_LEVELS], age_ge2 [0:AGE_LEVELS]'}
$emptyExpr=if($emptyEncoding){'age_empty[AGE_LEVELS][0]'}else{'!age_any[AGE_LEVELS][0]'}
$oneExpr=if($emptyEncoding){'age_one[AGE_LEVELS][0]'}else{'(age_any[AGE_LEVELS][0] && !age_ge2[AGE_LEVELS][0])'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$oldPath=$env:PATH
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$oldPath
  @{sourceSha256=(Get-FileHash "$repo/rtl/backend/rv_issue_queue.sv").Hash;
    equationsSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body)));
    scope='Exact production single-row age tree, arbitrary binary older/ready sets; not whole-IQ sequential equivalence'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($entries in @(4,7,56,64)){foreach($negative in @($false,$true)){
    $name="e${entries}_"+$(if($negative){'negative'}else{'positive'})
    $inversion=if($negative){'!'}else{''}
    $fixture=@"
module iq_age_miter(input logic [$($entries-1):0] age_matrix_q,ready_now,
                    output logic mismatch);
  localparam int ENTRIES=$entries, AGE_LEVELS=`$clog2(ENTRIES), AGE_LEAVES=1<<AGE_LEVELS;
  logic [AGE_LEAVES-1:0] $declarations;
  generate
    $body
  endgenerate
  logic [ENTRIES-1:0] older_ready;
  logic reference_empty,reference_one;
  assign older_ready=age_matrix_q & ready_now;
  assign reference_empty=!(|older_ready);
  assign reference_one=(|older_ready) && ((older_ready & (older_ready-ENTRIES'(1)))=='0);
  assign mismatch=(($emptyExpr) != reference_empty) ||
                  (${inversion}($oneExpr) != reference_one);
endmodule
"@
    [IO.File]::WriteAllText("$run/$name.sv",$fixture,[Text.UTF8Encoding]::new($false))
    & "$ToolRoot/bin/yosys.exe" -Q -T -p "read_slang --top iq_age_miter $run/$name.sv; prep -top iq_age_miter -flatten; opt; sat -verify -prove mismatch 0 -show-inputs" *> "$run/$name.log"
    if($negative){
      if($LASTEXITCODE -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){throw "Negative control not rejected: $name"}
    }elseif($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)) {throw "Proof incomplete/failed: $name"}
    Write-Output "PASS $name"
  }}
} finally {$env:PATH=$oldPath; & subst "$drive`:" /d | Out-Null}
