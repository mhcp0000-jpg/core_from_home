param(
  [Parameter(Mandatory=$true)][string]$RtlPath,
  [Parameter(Mandatory=$true)][string]$BuildRoot,
  [string]$ReferenceRtl='rtl/backend/rv_int_alu.sv',
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite'
)
# All original result outputs, arbitrary binary operands/opcode/word flag.
# Width variants are unit proof fixtures, NEVER a whole-core hardware override.
# This is not independent ISA, IEEE four-state, or physical timing sign-off.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$candidate=(Resolve-Path -LiteralPath $RtlPath).Path
$reference=(Resolve-Path -LiteralPath $ReferenceRtl).Path
$build=[IO.Path]::GetFullPath($BuildRoot)
foreach($path in @($candidate,$reference,$build)){
  if(!$path.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw 'Source/output must remain below workspace'
  }
}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No ASCII workspace alias'}
$savedPath=$env:PATH;$savedTemp=$env:TEMP;$savedTmp=$env:TMP
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force "$run/tmp" | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$savedPath
  $env:TEMP="$run/tmp";$env:TMP="$run/tmp"
  $gold=(Get-Content -LiteralPath $reference -Raw) -replace '\bmodule rv_int_alu\b','module rv_int_alu_reference'
  [IO.File]::WriteAllText("$run/reference.sv",$gold,[Text.UTF8Encoding]::new($false))
  Copy-Item -LiteralPath $candidate -Destination "$run/candidate.sv"
  Copy-Item "$repo/rtl/rv_ooo_pkg.sv" "$run/pkg.sv"
  $record=@{passed=$false;candidateSha256=(Get-FileHash $candidate).Hash;
    referenceSha256=(Get-FileHash $reference).Hash;packageSha256=(Get-FileHash "$run/pkg.sv").Hash;
    scope='All result bits, unconstrained binary inputs/opcode/word flag; NOT ISA/IEEE-X/STA';cases=@()}
  foreach($cfg in @(@(32,0),@(64,0),@(32,1))){
    $width,$negative=$cfg;$name="w${width}"+$(if($negative){'_negative'}else{''})
    $corruption=if($negative){" ^ WIDTH'(1)"}else{''}
    $fixture=@"
module alu_miter #(parameter int WIDTH=32)(
 input logic [WIDTH-1:0] a,b,
 input rv_ooo_pkg::int_alu_op_e op,
 input logic word_op,
 output logic mismatch);
 logic [WIDTH-1:0] expected,actual;
 rv_int_alu_reference #(.XLEN(WIDTH)) gold(.operand_a_i(a),.operand_b_i(b),
  .operation_i(op),.word_operation_i(word_op),.result_o(expected));
 rv_int_alu #(.XLEN(WIDTH)) candidate(.operand_a_i(a),.operand_b_i(b),
  .operation_i(op),.word_operation_i(word_op),.result_o(actual));
 assign mismatch=expected != (actual$corruption);
endmodule
"@
    [IO.File]::WriteAllText("$run/$name.sv",$fixture,[Text.UTF8Encoding]::new($false))
    $command="read_slang --std 1800-2017 --top alu_miter -G WIDTH=$width --ignore-assertions --ignore-initial $run/pkg.sv $run/reference.sv $run/candidate.sv $run/$name.sv; prep -top alu_miter -flatten; opt; techmap; opt; abc -g simple; opt_clean; sat -verify -prove mismatch 0 -show-inputs"
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $command *> "$run/$name.log"
    $code=$LASTEXITCODE;$log=Get-Content "$run/$name.log" -Raw
    $passed=if($negative){$code -ne 0 -and $log -match 'proof did fail'}else{$code -eq 0 -and $log -match 'SUCCESS!'}
    $record.cases+=@{name=$name;negative=[bool]$negative;passed=$passed;exitCode=$code}
    $record | ConvertTo-Json -Depth 6 | Set-Content "$run/report.json"
    if(!$passed){throw "Incomplete/failed ALU check: $name"}
    Write-Output "PASS $name"
  }
  $record.passed=$true
  $record | ConvertTo-Json -Depth 6 | Set-Content "$run/report.json"
} finally {
  $env:PATH=$savedPath;$env:TEMP=$savedTemp;$env:TMP=$savedTmp
  & subst "$drive`:" /d | Out-Null
}
