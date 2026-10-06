$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$cfg=& "$PSScriptRoot/read_core_config.ps1" -PackagePath "$repo/rtl/rv_ooo_pkg.sv"
$expected=@{AGU_LOAD_BYPASS=1;EARLY_LOAD_SELECT=1;COMPATIBLE_PAIR_SELECT=0;BRANCH_TAG_PIPELINE=1;DIV_TAG_PIPELINE=1;INT_ISSUE_PIPELINE=1;BR_CHECKPOINTS=8}
foreach($name in $expected.Keys) {
  if($cfg.$name -ne $expected[$name]) {throw "Published profile changed: $name; update the expected profile only after matched regressions"}
}
foreach($file in @('rtl/rv_ooo_core.sv','rtl/backend/rv_backend.sv','rtl/soc/rv_soc_top.sv','tb/e2e/dpi/rv_soc_dpi_tb.sv','tb/e2e/dpi/rv_soc_htif_dpi_tb.sv')) {
  $source=Get-Content "$repo/$file" -Raw
  foreach($name in $expected.Keys) {
    if($source -notmatch ('=\s*rv_ooo_pkg::CORE_CFG_'+$name+'\b')) {throw "PKG binding missing $file $name"}
  }
}
foreach($file in @('scripts/run_soc_elf_test.ps1','scripts/run_full_core_timing.ps1','scripts/run_open_timing.ps1','scripts/run_open_timing.sh')) {
  $source=Get-Content "$repo/$file" -Raw
  if($source -match '(?m)(-G(?:\s|Core)|RV_AGU_LOAD_BYPASS|defparam)'){throw "Tool hardware override in $file"}
}
foreach($file in @('tb/e2e/dpi/rv_soc_dpi_tb.sv','tb/e2e/dpi/rv_soc_htif_dpi_tb.sv')) {
  $source=Get-Content "$repo/$file" -Raw
  if($source -notmatch '\[CORE_CONFIG\]' -or $source -match 'RV_AGU_LOAD_BYPASS'){throw "Configuration banner missing or macro override present $file"}
}
foreach($file in @('scripts/read_core_config.ps1','scripts/run_full_core_timing.ps1','scripts/run_soc_elf_test.ps1','scripts/run_open_timing.ps1','scripts/run_integration_tests.ps1')) {
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile("$repo/$file",[ref]$tokens,[ref]$errors)
  if($errors.Count){throw "PowerShell syntax error $file : $errors"}
}
Write-Output 'PASS core PKG profile, top/SoC/backend/TB default bindings, no hardware tool overrides, configuration banners and PowerShell syntax'
