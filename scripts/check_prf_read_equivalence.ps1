param([string]$BuildRoot='', [string]$Baseline='e9d135b', [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite')
# Native original read mux vs decoded tree. No valid-tag assumptions: undefined
# out-of-range tags are compared using Yosys undef semantics. Same state/ports,
# reset, allocation-wins, write priority, x0 and WRITE_BYPASS modes are checked.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/prf_read_formal'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be below workspace'}
$reference=(& git show "${Baseline}:rtl/backend/rv_phys_regfile.sv") -join "`n"
if($LASTEXITCODE){throw 'Missing immutable PRF reference'}
$candidate=Get-Content "$repo/rtl/backend/rv_phys_regfile.sv" -Raw
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No unused ASCII alias'}
$oldPath=$env:PATH
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$oldPath
  @{sourceSha256=(Get-FileHash "$repo/rtl/backend/rv_phys_regfile.sv").Hash;baseline=$Baseline;
    scope='All matched state/output equivalence, undef-enabled induction, no valid-address assumptions; not ISA/STA proof'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  # Explicit test geometry in saved SV, NOT hardware tool overrides on core.
  foreach($cfg in @(@(32,7,4,0,1),@(32,80,16,0,1),@(32,80,8,0,0),@(64,7,4,1,1))){
    $width,$rows,$reads,$bypass,$zero=$cfg
    $name="w${width}_r${rows}_p${reads}_b${bypass}_z${zero}"
    foreach($kind in @('gold','gate')){
      $body=if($kind -eq 'gold'){$reference}else{$candidate}
      $body=$body -replace '\bmodule rv_phys_regfile\b',"module $kind"
      foreach($parameter in @(@('DATA_WIDTH',$width),@('PHYS_REGS',$rows),@('READ_PORTS',$reads),@('INITIAL_MAPPED_REGS',[math]::Min(32,$rows)))){
        $pattern='(parameter int unsigned '+$parameter[0]+'\s*=\s*)\d+'
        $body=$body -replace $pattern,('${1}'+$parameter[1])
      }
      $body=$body -replace "(parameter bit ZERO_REGISTER\s*=\s*)1'b[01]",('${1}'+"1'b$zero")
      $body=$body -replace "(parameter bit WRITE_BYPASS\s*=\s*)1'b[01]",('${1}'+"1'b$bypass")
      [IO.File]::WriteAllText("$run/${name}_${kind}.sv",$body,[Text.UTF8Encoding]::new($false))
    }
    $cmd="read_slang --ignore-assertions --ignore-initial --no-implicit-memories --top gold $run/${name}_gold.sv; prep -top gold; design -stash ref; " +
      "read_slang --ignore-assertions --ignore-initial --no-implicit-memories --top gate $run/${name}_gate.sv; prep -top gate; design -stash dut; " +
      'design -copy-from ref gold; design -copy-from dut gate; equiv_make gold gate equiv; hierarchy -top equiv; equiv_struct -fwd -icells; equiv_simple -undef -short -seq 1; equiv_induct -undef -seq 2; equiv_status -assert'
    & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
    if($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'Equivalence successfully proven!' -Quiet)){throw "PRF proof failed/incomplete: $name"}
    Write-Output "PASS $name"
  }
} finally {$env:PATH=$oldPath; & subst "$drive`:" /d | Out-Null}
