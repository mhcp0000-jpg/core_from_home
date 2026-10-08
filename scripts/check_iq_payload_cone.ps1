param([string]$SourceRoot='', [string]$BuildRoot='', [string]$Baseline='8e2e255',
      [string]$ToolRoot='C:/rv_toolchains/oss-cad-suite')
# Prove the entire changed output cone for arbitrary selection/payload values,
# including EMPTY and multi-hot inputs. Verify byte-identical RTL everywhere
# outside that combinational block (including every sequential update).
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(!$SourceRoot){$SourceRoot=$repo}
if(!$BuildRoot){$BuildRoot=Join-Path $repo 'out/iq_payload_cone_proof'}
$build=[IO.Path]::GetFullPath($BuildRoot)
if(!$build.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be inside workspace'}
$gold=(& git -C $repo show "${Baseline}:rtl/backend/rv_issue_queue.sv") -join "`n"
if($LASTEXITCODE){throw 'Missing immutable reference'}
$gate=(Get-Content "$SourceRoot/rtl/backend/rv_issue_queue.sv" -Raw).Replace("`r`n","`n").TrimEnd()
$gold=$gold.TrimEnd()
$begin="  always_comb begin`n    candidate_valid_o"
$end="`n  // Lowest two free slots,"
function Output-Block([string]$text){
  $start=$text.IndexOf($begin);$stop=$text.IndexOf($end,$start)
  if($start -lt 0 -or $stop -lt $start){throw 'Unique payload output block missing'}
  @{prefix=$text.Substring(0,$start);block=$text.Substring($start,$stop-$start);suffix=$text.Substring($stop)}
}
$a=Output-Block $gold;$b=Output-Block $gate
if($a.prefix -cne $b.prefix -or $a.suffix -cne $b.suffix){throw 'RTL outside changed combinational block differs; cone proof insufficient'}
$type=[regex]::Match($gold,'(?s)typedef struct packed \{[^}]+\} cand_payload_t;').Value
if(!$type){throw 'Candidate type missing'}
$indexStop=$gold.IndexOf('  // Pack every per-entry field once')
$indexStart=$gold.LastIndexOf('  always_comb begin',$indexStop)
$index=$gold.Substring($indexStart,$indexStop-$indexStart)
$treeStart=$gold.IndexOf('  for (genvar slot = 0; slot < SELECT_WIDTH; slot++) begin : g_payload_select')
$tree=$gold.Substring($treeStart,$gold.IndexOf($begin)-$treeStart)
$ports=[regex]::Matches($gold,'\boutput\s+(logic|rv_ooo_pkg::\w+)((?:\s|\[[^\]]+\])*)(candidate_\w+)\s*,')
if(!$ports.Count){throw 'Output schema not found'}
$declarations=($ports | ForEach-Object {$_.Groups[1].Value+$_.Groups[2].Value+$_.Groups[3].Value+';'}) -join "`n"
$names=@($ports | ForEach-Object {$_.Groups[3].Value})+@('candidate_final_phase')
$expectedNames=@([regex]::Matches($a.block,'(?m)^    (candidate_\w+)\s*=') | ForEach-Object {$_.Groups[1].Value})
if(Compare-Object ($names | Sort-Object) ($expectedNames | Sort-Object)){
  throw 'Output declarations do not cover every initialized candidate output/internal final-phase bit'
}
$bundle='{'+($names -join ',')+'}'
$drive=@('M','N','P','Q','R','S','T','U','W','X','Y','Z') | Where-Object {!(Test-Path "$_`:\")} | Select-Object -First 1
if(!$drive){throw 'No ASCII alias'}
$oldPath=$env:PATH;$pushed=$false
try{
  & subst "$drive`:" $repo
  if($LASTEXITCODE){throw 'subst failed'}
  Push-Location "$drive`:/";$pushed=$true
  $run="$drive`:/"+$build.Substring($repo.Length+1).Replace('\','/')
  New-Item -ItemType Directory -Force -Path $run | Out-Null
  $env:PATH="$ToolRoot/bin;$ToolRoot/lib;"+$oldPath
  @{baseline=(& git rev-parse $Baseline);candidateSha256=(Get-FileHash "$SourceRoot/rtl/backend/rv_issue_queue.sv").Hash;
    outsideChangedBlockIdentical=$true;
    scope='Exact output block + exact index/selection tree; all inputs incl empty/multihot; unchanged sequential RTL verified lexically; not whole-core ISA proof'} |
    ConvertTo-Json | Set-Content "$run/manifest.json" -Encoding UTF8
  foreach($cfg in @(@(32,4),@(32,7),@(32,56),@(64,7))){
    $xlen,$entries=$cfg
    $constants=@'
localparam XLEN=@XLEN@, ENTRIES=@ENTRIES@, SELECT_WIDTH=2, PHYS_TAG_WIDTH=7,
ROB_SEQ_WIDTH=rv_ooo_pkg::ROB_SEQ_WIDTH, EXEC_PORTS=5, OP_WIDTH=16,
LQ_INDEX_WIDTH=5, SQ_INDEX_WIDTH=4, CHECKPOINT_ID_WIDTH=3,
INDEX_WIDTH=$clog2(ENTRIES), FU_ONEHOT_WIDTH=1 << $bits(rv_ooo_pkg::fu_class_e);
'@.Replace('@XLEN@',"$xlen").Replace('@ENTRIES@',"$entries")
    foreach($negative in @($false,$true)){
      $name="x${xlen}_e${entries}_"+$(if($negative){'negative'}else{'positive'})
      $gateBlock=$b.block
      if($negative){
        $needle='candidate_pc_o[slot]           = sel_pl[slot].pc;'
        if(!$gateBlock.Contains($needle)){throw 'Negative control point missing'}
        $gateBlock=$gateBlock.Replace($needle,"candidate_pc_o[slot]           = sel_pl[slot].pc ^ XLEN'(1);")
      }
      $source="package iq_cone_types; import rv_ooo_pkg::*;`n$constants`n$type`nendpackage`n" +
        'module iq_payload_cone_miter(input logic [iq_cone_types::ENTRIES-1:0] first_hot,second_hot,' +
        'input iq_cone_types::cand_payload_t entry_payload[0:iq_cone_types::ENTRIES-1],' +
        'input logic [iq_cone_types::FU_ONEHOT_WIDTH-1:0] entry_fu_onehot[0:iq_cone_types::ENTRIES-1],' +
        'input logic [iq_cone_types::ENTRIES-1:0] store_data_ready_vec,' +
        'input logic flush_all_i,flush_younger_i, output logic mismatch);' +
        "`nimport rv_ooo_pkg::FU_STORE; import iq_cone_types::*;`n"
      foreach($kind in @('gold','gate')){
        $block=if($kind -eq 'gold'){$a.block}else{$gateBlock}
        $local=@'
localparam CAND_W=$bits(cand_payload_t),PAYLOAD_LEAVES=1 << $clog2(ENTRIES),SELECT_BUNDLE_W=CAND_W+FU_ONEHOT_WIDTH+1;
logic [SELECT_WIDTH-1:0] am_found,candidate_final_phase;
logic [SELECT_WIDTH-1:0][INDEX_WIDTH-1:0] am_index;
logic [ENTRIES-1:0] am_first,am_second,valid_vec;
logic valid_q[0:ENTRIES-1];
for(genvar n=0;n<ENTRIES;n++) assign valid_q[n]=1'b0;
assign am_first=first_hot;assign am_second=second_hot;
logic [SELECT_WIDTH-1:0][ENTRIES-1:0] am_hot;
assign am_hot[0]=am_first;assign am_hot[1]=am_second;
logic [CAND_W-1:0] sel_payload[0:SELECT_WIDTH-1];
cand_payload_t sel_pl[0:SELECT_WIDTH-1];
logic [SELECT_WIDTH-1:0][FU_ONEHOT_WIDTH-1:0] sel_fu_onehot;
logic [SELECT_WIDTH-1:0] sel_store_data_ready;
logic [SELECT_BUNDLE_W-1:0] payload_tree[0:SELECT_WIDTH-1][1:2*PAYLOAD_LEAVES-1];
'@
        $source+="if(1) begin:g_$kind`n$local`n$declarations`n$index`n$tree`n$block`n" +
          "logic [`$bits($bundle)-1:0] result; assign result=$bundle;`nend`n"
      }
      $source+="assign mismatch=g_gold.result!=g_gate.result; endmodule`n"
      [IO.File]::WriteAllText("$run/$name.sv",$source,[Text.UTF8Encoding]::new($false))
      $cmd="read_slang --std 1800-2017 --top iq_payload_cone_miter rtl/rv_ooo_pkg.sv $run/$name.sv; prep -top iq_payload_cone_miter -flatten; opt; sat -verify -prove mismatch 0"
      & "$ToolRoot/bin/yosys.exe" -Q -T -p $cmd *> "$run/$name.log"
      if($negative){if($LASTEXITCODE -eq 0 -or !(Select-String "$run/$name.log" -Pattern 'proof did fail' -Quiet)){throw "Negative not rejected: $name"}}
      elseif($LASTEXITCODE -ne 0 -or !(Select-String "$run/$name.log" -Pattern 'SUCCESS!' -Quiet)){throw "Cone proof incomplete/failed: $name"}
      Write-Output "PASS IQ exact payload cone $name"
    }
  }
  Write-Output 'PASS IQ payload cone all configurations and negative controls; unchanged sequential RTL verified'
}finally{$env:PATH=$oldPath;if($pushed){Pop-Location};& subst "$drive`:" /d | Out-Null}
