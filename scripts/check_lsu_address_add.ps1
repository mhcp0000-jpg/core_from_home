param(
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite',
  [string]$BuildRoot=''
)
# All-input two-state arithmetic proof of the exact production address_add
# function. Not a full-core/4-state equivalence or clock sign-off.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/lsu_address_add_formal'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'Output must be below workspace'
}
$source=Get-Content "$repo/rtl/backend/rv_lsu_pipe.sv" -Raw
$match=[regex]::Match($source,'(?s)function automatic logic \[XLEN-1:0\] address_add\(.*?endfunction')
if(!$match.Success){throw 'Production address_add function missing'}
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$oldPath=$env:PATH
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$oldPath
  @{sourceSha256=(Get-FileHash "$repo/rtl/backend/rv_lsu_pipe.sv").Hash;
    scope='Exact address_add function, all binary input pairs, XLEN32/64, modulo arithmetic; negative control required'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($xlen in @(32,64)){foreach($negative in @($false,$true)){
    $name="x${xlen}_"+$(if($negative){'negative'}else{'positive'})
    $mask=if($negative){" ^ XLEN'(1)"}else{''}
    # Test geometry is literal SV, not a hardware tool override on the core.
    $miter=@"
module lsu_address_miter(input logic [$($xlen-1):0] lhs,rhs,output logic mismatch);
localparam int XLEN=$xlen;
$($match.Value)
assign mismatch = ((address_add(lhs,rhs)$mask) != (lhs+rhs));
endmodule
"@
    [IO.File]::WriteAllText("$run/$name.sv",$miter,[Text.UTF8Encoding]::new($false))
    $cmd="read_slang --std 1800-2017 --top lsu_address_miter $run/$name.sv; prep -top lsu_address_miter -flatten; opt; sat -verify -prove mismatch 0 -show-inputs"
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
    if($negative){
      if($LASTEXITCODE -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){throw "Negative control not rejected: $name"}
    }elseif($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)){
      throw "Proof failed/incomplete: $name"
    }
    Write-Output "PASS $name"
  }}
}finally{
  $env:PATH=$oldPath
  & subst "$drive`:" /d | Out-Null
}
