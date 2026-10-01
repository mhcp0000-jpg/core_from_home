param(
  [string]$Baseline = "3f9b0ea",
  [string]$BuildRoot = "",
  [string]$VerilatorRoot = "C:\rv_toolchains\verilator-5.050",
  [string]$W64DevkitRoot = "C:\rv_toolchains\w64devkit-2.9.1\w64devkit",
  [int]$BuildJobs = 4
)
# Stateful cycle equality against an immutable reference. Outputs are ignored
# out/ artifacts; no worktree or source checkout is changed.
$ErrorActionPreference="Stop"
$repo=Split-Path -Parent $PSScriptRoot
$drive=@("Z","Y","X","W","U","T","S","R") |
  Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1
if(!$drive){throw "No unused ASCII drive letter"}
$oldPath=$env:PATH
$oldRoot=$env:VERILATOR_ROOT
$locationPushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw "subst failed"}
  Push-Location "$drive`:/"
  $locationPushed=$true
  if(!$BuildRoot){$BuildRoot="$drive`:/out/predictor_equivalence"}
  New-Item -ItemType Directory -Force $BuildRoot | Out-Null
  $ref=& git show "${Baseline}:rtl/frontend/rv_branch_predictor.sv"
  if($LASTEXITCODE){throw "Cannot read immutable predictor reference $Baseline"}
  $ref=($ref -join "`n") -replace "module rv_branch_predictor\b","module rv_branch_predictor_ref"
  $refPath="$BuildRoot/reference.sv"
  [IO.File]::WriteAllText($refPath,$ref,[Text.UTF8Encoding]::new($false))
  @{
    referenceCommit=(& git rev-parse $Baseline)
    candidateSha256=(Get-FileHash "$drive`:/rtl/frontend/rv_branch_predictor.sv" -Algorithm SHA256).Hash
    testbenchSha256=(Get-FileHash "$drive`:/tb/unit/frontend/rv_branch_predictor_equiv_tb.sv" -Algorithm SHA256).Hash
    cyclesPerConfiguration=100000
    configurations=@("XLEN32/PHT32/BTB16/WAYS2","XLEN64/PHT32/BTB16/WAYS2",
                     "XLEN32/PHT2048/BTB256/WAYS4","XLEN64/PHT2048/BTB256/WAYS4")
    scope="Stateful all-public-output comparison, not independent ISA proof"
  } | ConvertTo-Json | Set-Content "$BuildRoot/run_manifest.json" -Encoding UTF8
  $env:PATH="$W64DevkitRoot\bin;"+$oldPath
  $env:VERILATOR_ROOT=$VerilatorRoot
  foreach($config in @(@(32,32,16,2),@(64,32,16,2),@(32,2048,256,4),@(64,2048,256,4))){
    $width,$pht,$btb,$ways=$config
    $build="$BuildRoot/x${width}_pht${pht}"
    New-Item -ItemType Directory -Force $build | Out-Null
    $savedErrorAction=$ErrorActionPreference
    $ErrorActionPreference="Continue"
    & "$VerilatorRoot\bin\verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal -Werror-UNOPTFLAT `
      --top-module rv_branch_predictor_equiv_tb --Mdir $build "-GXLEN=$width" "-GPHT_ENTRIES=$pht" `
      "-GBTB_ENTRIES=$btb" "-GBTB_WAYS=$ways" "$drive`:/rtl/rv_ooo_pkg.sv" $refPath `
      "$drive`:/rtl/frontend/rv_branch_predictor.sv" "$drive`:/tb/unit/frontend/rv_branch_predictor_equiv_tb.sv" *> "$build/compile.log"
    $ErrorActionPreference=$savedErrorAction
    if($LASTEXITCODE){throw "Predictor generation failed: $build/compile.log"}
    & "$W64DevkitRoot\bin\make.exe" -j $BuildJobs -C $build -f Vrv_branch_predictor_equiv_tb.mk `
      CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$build/build.log"
    if($LASTEXITCODE){throw "Predictor C++ build failed: $build/build.log"}
    & "$build/Vrv_branch_predictor_equiv_tb.exe" *> "$build/result.log"
    if($LASTEXITCODE){throw "Predictor equivalence failed: $build/result.log"}
    Get-Content "$build/result.log" | Select-Object -First 1
  }
} finally {
  if($locationPushed){Pop-Location}
  $env:PATH=$oldPath
  $env:VERILATOR_ROOT=$oldRoot
  & subst "$drive`:" /d | Out-Null
}
