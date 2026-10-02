param(
  [string]$Baseline='081e714',
  [string]$CandidateRtl='rtl/frontend/rv_fetch_target_buffer.sv',
  [string]$BuildRoot='',
  [string]$VerilatorRoot='C:\rv_toolchains\verilator-5.050',
  [string]$W64DevkitRoot='C:\rv_toolchains\w64devkit-2.9.1\w64devkit',
  [int]$BuildJobs=2
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$drive=@('Z','Y','X','W','U','T','S','R') |
  Where-Object { !(Test-Path "$_`:\") } | Select-Object -First 1
if(!$drive){throw 'No unused ASCII drive'}
$oldPath=$env:PATH; $oldRoot=$env:VERILATOR_ROOT; $pushed=$false
try {
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/"; $pushed=$true
  if(!$BuildRoot){$BuildRoot='out/ftb_equivalence'}
  New-Item -ItemType Directory -Force $BuildRoot | Out-Null
  $ref=& git show "${Baseline}:rtl/frontend/rv_fetch_target_buffer.sv"
  if($LASTEXITCODE){throw 'Cannot read immutable FTB reference'}
  $ref=($ref -join "`n") -replace 'module rv_fetch_target_buffer\b','module rv_fetch_target_buffer_ref'
  $refPath="$BuildRoot/reference.sv"
  [IO.File]::WriteAllText($refPath,$ref,[Text.UTF8Encoding]::new($false))
  $tb='tb/unit/frontend/rv_fetch_target_buffer_equiv_tb.sv'
  $configs=@(@(32,16,16,1),@(64,16,16,1),@(32,16,16,2),@(64,16,16,2),
             @(32,8,2,2),@(64,32,32,4),@(32,16,2,4),@(64,8,16,4))
  @{
    referenceCommit=(& git rev-parse $Baseline)
    candidateRtl=$CandidateRtl
    candidateSha256=(Get-FileHash $CandidateRtl -Algorithm SHA256).Hash
    testbenchSha256=(Get-FileHash $tb -Algorithm SHA256).Hash
    configurations=$configs
    cyclesPerConfiguration=100000
    scope='All public output (including invalid/miss payload) and original FF state; not ISA/formal proof'
  } | ConvertTo-Json -Depth 5 | Set-Content "$BuildRoot/run_manifest.json" -Encoding UTF8
  $env:PATH="$W64DevkitRoot/bin;"+$oldPath
  $env:VERILATOR_ROOT=$VerilatorRoot
  foreach($config in $configs){
    $width,$fetch,$entries,$ports=$config
    $build="$BuildRoot/p${width}_f${fetch}_e${entries}_ports${ports}"
    New-Item -ItemType Directory -Force $build | Out-Null
    $ErrorActionPreference='Continue'
    & "$VerilatorRoot/bin/verilator_bin.exe" --cc --exe --main --timing --assert -Wno-fatal -Werror-UNOPTFLAT `
      --top-module rv_fetch_target_buffer_equiv_tb --Mdir $build "-GPADDR_WIDTH=$width" `
      "-GFETCH_BYTES=$fetch" "-GENTRIES=$entries" "-GLOOKUP_PORTS=$ports" $refPath $CandidateRtl $tb *> "$build/compile.log"
    $generateCode=$LASTEXITCODE; $ErrorActionPreference='Stop'
    if($generateCode){throw "FTB generation failed: $build/compile.log"}
    $ErrorActionPreference='Continue'
    & "$W64DevkitRoot/bin/make.exe" -j $BuildJobs -C $build -f Vrv_fetch_target_buffer_equiv_tb.mk `
      CXX=g++ CC=gcc LINK=g++ VM_PARALLEL_BUILDS=1 *> "$build/build.log"
    $buildCode=$LASTEXITCODE; $ErrorActionPreference='Stop'
    if($buildCode){throw "FTB build failed: $build/build.log"}
    & "$build/Vrv_fetch_target_buffer_equiv_tb.exe" *> "$build/result.log"
    if($LASTEXITCODE){throw "FTB equivalence failed: $build/result.log"}
    Get-Content "$build/result.log" | Select-Object -First 1
  }
} finally {
  if($pushed){Pop-Location}
  $env:PATH=$oldPath; $env:VERILATOR_ROOT=$oldRoot
  & subst "$drive`:" /d | Out-Null
}
