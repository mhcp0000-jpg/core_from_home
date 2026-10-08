param(
  [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite',
  [string]$BuildRoot=''
)
# Extract production routing; prove all input combinations at XLEN32/64 and
# require an injected one-bit routing error to fail. No core tool overrides.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/alu_input_route_proof'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'BuildRoot must be below the repository'
}
$backend=Get-Content "$repo/rtl/backend/rv_backend.sv" -Raw
$match=[regex]::Match($backend,'(?s)  logic \[1:0\]\[XLEN-1:0\] cand_alu_a,cand_alu_b;.*?(?=\r?\n`ifndef SYNTHESIS)')
if(!$match.Success){throw 'Expected unique production ALU routing block not found'}
$template=Get-Content "$repo/tb/formal/rv_alu_input_route_template.sv" -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') |
  Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive alias'}
$savedPath=$env:PATH
$pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$savedPath
  @{
    backendSha256=(Get-FileHash rtl/backend/rv_backend.sv).Hash
    aluSha256=(Get-FileHash rtl/backend/rv_int_alu.sv).Hash
    packageSha256=(Get-FileHash rtl/rv_ooo_pkg.sv).Hash
    templateSha256=(Get-FileHash tb/formal/rv_alu_input_route_template.sv).Hash
    scope='Combinational two-state ALU input/result equivalence when issued and not flushed; not whole-core proof'
  } | ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($xlen in @(32,64)) {
    foreach($negative in @($false,$true)) {
      $name="x${xlen}_"+$(if($negative){'negative'}else{'positive'})
      $block=$match.Value
      if($negative){
        $original='alu_a[port]=cand_alu_a[port_candidate[port]];'
        if(!$block.Contains($original)){throw 'Negative control insertion point missing'}
        $block=$block.Replace($original,"alu_a[port]=cand_alu_a[port_candidate[port]] ^ XLEN'(1);")
      }
      $generated=$template.Replace('@XLEN@',"$xlen").Replace('@BACKEND_ALU_BLOCK@',$block)
      [IO.File]::WriteAllText("$run/$name.sv",$generated,[Text.UTF8Encoding]::new($false))
      $cmd="read_slang --std 1800-2017 --top rv_alu_input_route_miter rtl/rv_ooo_pkg.sv rtl/backend/rv_int_alu.sv $run/$name.sv; prep -top rv_alu_input_route_miter -flatten; opt; sat -verify -prove mismatch 0 -show-inputs"
      & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
      $code=$LASTEXITCODE
      if($negative){
        if($code -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){
          throw "Negative control was not rejected: $name (exit=$code)"
        }
        Write-Output "PASS negative control rejected XLEN=$xlen"
      } else {
        if($code -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)){
          throw "Routing equivalence not proven: $name (exit=$code)"
        }
        Write-Output "PASS all-input ALU routing/result equivalence XLEN=$xlen"
      }
    }
  }
} finally {
  $env:PATH=$savedPath
  if($pushed){Pop-Location}
  & subst "$drive`:" /d | Out-Null
}
