#!/usr/bin/env python3
"""Test observation-mask generation only; this is not an RTL/ISA proof."""
from types import SimpleNamespace
import unittest

from check_lsq_random_equivalence import fixture


SOURCE = """module rv_lsq #(parameter int UNUSED=0) (
  input logic clk_i,
  input logic rst_ni,
  input logic [1:0] load_commit_valid_i,
  input logic [1:0] store_commit_valid_i,
  output logic [1:0] load_commit_ready_o,
  output logic [1:0] store_commit_ready_o,
  output logic [1:0] sb_enq_valid_o
);
endmodule
"""


class ReadyObservationTest(unittest.TestCase):
    def args(self, qualified=None):
        args = SimpleNamespace(loads=4, stores=4, width=32,
                               early=1, bypass=1, cycles=1000)
        if qualified is not None:
            args.qualified_commit_ready = qualified
        return args

    def test_default_and_legacy_call_compare_all_ready_bits(self):
        for option in (None, False):
            generated = fixture(SOURCE, SOURCE, self.args(option))
            for kind in ("load", "store"):
                self.assertIn(
                    f"if(dut_{kind}_commit_ready_o !== ref_{kind}_commit_ready_o)",
                    generated,
                )

    def test_opt_in_masks_only_ready_not_store_effect(self):
        generated = fixture(SOURCE, SOURCE, self.args(True))
        for kind in ("load", "store"):
            self.assertIn(
                f"if((dut_{kind}_commit_ready_o & {kind}_commit_valid_i) !== "
                f"(ref_{kind}_commit_ready_o & {kind}_commit_valid_i))",
                generated,
            )
        self.assertIn("if(dut_sb_enq_valid_o !== ref_sb_enq_valid_o)", generated)
        self.assertNotIn("dut_sb_enq_valid_o &", generated)

    def test_mask_detects_every_active_lane_difference(self):
        for actual in range(4):
            for reference in range(4):
                for valid in range(4):
                    self.assertEqual(
                        (actual & valid) != (reference & valid),
                        any((valid & (1 << lane)) and
                            ((actual ^ reference) & (1 << lane))
                            for lane in range(2)),
                    )


if __name__ == "__main__":
    unittest.main()
