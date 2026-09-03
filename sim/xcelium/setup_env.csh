#!/bin/csh
# csh/tcsh servers: run from repository root with `source sim/xcelium/setup_env.csh`.

if (! -d "rtl" || ! -d "sim/xcelium") then
  echo "ERROR: setup_env.csh must be sourced from the repository root."
  exit 2
endif

setenv CORE_ROOT `pwd`
setenv RTL_DIR "${CORE_ROOT}/rtl"
setenv TB_DIR "${CORE_ROOT}/tb"
setenv XCELIUM_DIR "${CORE_ROOT}/sim/xcelium"

echo "CORE_ROOT   = ${CORE_ROOT}"
echo "RTL_DIR     = ${RTL_DIR}"
echo "TB_DIR      = ${TB_DIR}"
echo "XCELIUM_DIR = ${XCELIUM_DIR}"
