"""Parse and elaborate the RV32/RV64 architecture shell with pyslang."""

from pathlib import Path
import os
import sys

from pyslang import DiagnosticEngine
from pyslang.ast import Compilation
from pyslang.syntax import SyntaxTree


ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "rtl/soc/rv_soc_pkg.sv",
    "rtl/soc/rv_axi4_if.sv",
    "rtl/soc/rv_local_mem_if.sv",
    "rtl/soc/rv_local_to_axi_bridge.sv",
    "rtl/soc/rv_axi_to_local_bridge.sv",
    "rtl/soc/rv_axi_error_slave.sv",
    "rtl/soc/rv_axi_xbar.sv",
    "rtl/soc/rv_soc_map_check.sv",
    "rtl/soc/rv_soc_addr_decode.sv",
    "rtl/soc/rv_sram_1r1w.sv",
    "rtl/soc/rv_tim_2bank.sv",
    "rtl/soc/rv_clint.sv",
    "rtl/soc/rv_bootrom.sv",
    "rtl/soc/rv_hostif.sv",
    "rtl/soc/rv_plic.sv",
    "rtl/soc/rv_d_fabric.sv",
    "rtl/soc/rv_i_fabric.sv",
    "rtl/soc/rv_soc_top.sv",
    "rtl/rv_ooo_pkg.sv",
    "rtl/frontend/rv_c_expander.sv",
    "rtl/frontend/rv_fetch_queue.sv",
    "rtl/frontend/rv_branch_predictor.sv",
    "rtl/backend/rv_decode2.sv",
    "rtl/backend/rv_lsq_order_check.sv",
    "rtl/backend/rv_lsu_pipe.sv",
    "rtl/backend/rv_lsq.sv",
    "rtl/backend/rv_store_buffer.sv",
    "rtl/backend/rv_lsu_cluster.sv",
    "rtl/backend/rv_rename2.sv",
    "rtl/backend/rv_phys_regfile.sv",
    "rtl/backend/rv_issue_queue.sv",
    "rtl/backend/rv_issue_arbiter.sv",
    "rtl/backend/rv_int_alu.sv",
    "rtl/backend/rv_branch_unit.sv",
    "rtl/backend/rv_multiplier.sv",
    "rtl/backend/rv_divider.sv",
    "rtl/backend/rv_fpu.sv",
    "rtl/backend/rv_writeback_arbiter.sv",
    "rtl/backend/rv_branch_recovery.sv",
    "rtl/backend/rv_exec_result_buffer.sv",
    "rtl/backend/rv_csr_file.sv",
    "rtl/backend/rv_pmp.sv",
    "rtl/backend/rv_rob.sv",
    "rtl/frontend/rv_frontend.sv",
    "rtl/backend/rv_backend.sv",
    "rtl/rv_ooo_core.sv",
    "tb/elab/rv_ooo_elab_smoke.sv",
    "tb/elab/rv_soc_map_elab_smoke.sv",
    "tb/elab/rv_soc_top_elab_smoke.sv",
    "tb/elab/rv_soc_leaf_elab_smoke.sv",
    "tb/elab/rv_axi_bridge_elab_smoke.sv",
    "tb/elab/rv_axi_xbar_elab_smoke.sv",
    "tb/elab/rv_soc_peripheral_elab_smoke.sv",
    "tb/unit/rv_d_fabric_tb.sv",
    "tb/unit/rv_i_fabric_tb.sv",
    "tb/unit/rv_axi_bridge_tb.sv",
    "tb/unit/rv_soc_peripheral_tb.sv",
    "tb/unit/rv_soc_top_tb.sv",
    "tb/unit/rv_rename2_tb.sv",
    "tb/unit/rv_rob_tb.sv",
    "tb/unit/rv_issue_queue_tb.sv",
    "tb/unit/rv_issue_arbiter_tb.sv",
    "tb/unit/rv_phys_regfile_tb.sv",
    "tb/unit/rv_execute_units_tb.sv",
    "tb/unit/rv_multiplier_tb.sv",
    "tb/unit/rv_decode2_tb.sv",
    "tb/unit/rv_divider_tb.sv",
    "tb/unit/rv_fetch_queue_tb.sv",
    "tb/unit/rv_lsu_pipe_tb.sv",
    "tb/unit/rv_store_buffer_tb.sv",
    "tb/unit/rv_lsq_tb.sv",
    "tb/unit/rv_writeback_arbiter_tb.sv",
    "tb/unit/rv_branch_recovery_tb.sv",
    "tb/unit/rv_exec_result_buffer_tb.sv",
    "tb/unit/rv_csr_file_tb.sv",
    "tb/unit/rv_pmp_tb.sv",
    "tb/unit/rv_backend_int_tb.sv",
)


def main() -> int:
    # pyslang on Windows can fail to open an absolute path containing non-ANSI
    # characters. Enter the project root and use ASCII-only relative paths.
    os.chdir(ROOT)
    compilation = Compilation()
    for source in SOURCES:
        compilation.addSyntaxTree(SyntaxTree.fromFile(str(source)))

    compilation.getRoot()
    diagnostics = compilation.getAllDiagnostics()
    if diagnostics:
        report = DiagnosticEngine.reportAll(compilation.sourceManager, diagnostics)
        if report:
            print(report, file=sys.stderr)

    errors = sum(1 for diagnostic in diagnostics if diagnostic.isError())
    if errors:
        print(f"RTL check failed with {errors} error(s).", file=sys.stderr)
        return 1

    print(
        "RTL parse/elaboration passed: rv32_default, rv32_paddr34, "
        "rv64_smoke, soc_default_map, soc_relocated_map, soc_top, soc_leafs, "
        "d_fabric_tb, i_fabric_tb, axi_bridges, axi_xbar, peripherals, "
        "axi_bridge_tbs, soc_top_tb, rename2_tb, rob_tb, issue_queue_tb, "
        "issue_arbiter_tb, phys_regfile_tb, execute_units_tb, multiplier_tb, "
        "decode2_tb, divider_tb, fetch_queue_tb, lsu_pipe_tb, store_buffer_tb, "
        "lsq_tb, writeback_arbiter_tb, branch_recovery_tb, result_buffer_tb, "
        "csr_file_tb, pmp_tb, backend_int_tb"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
