#!/usr/bin/env python3
"""Small positive/negative coverage for the full-array structural cone tracer."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from trace_full_array_path import Graph


def netlist(extra="", source="\\src", endpoint="\\dst", gates=None):
    if gates is None:
        gates = r"""
  cell $_MUX_ $mux
    connect \A \src
    connect \B 1'0
    connect \S \other
    connect \Y \middle
  end
  cell $_AND_ $and
    connect \A \middle
    connect \B \other
    connect \Y \result
  end
"""
    return rf"""
module \top
  wire \src
  wire \other
  wire \middle
  wire \result
  wire \dst
  wire \other_dst
  wire width 2 \bus
  cell \DFF_X1 $source
    connect \D 1'0
    connect \Q {source}
  end
  cell \DFF_X1 $other
    connect \D 1'0
    connect \Q \other
  end
{gates}
  cell \DFF_X1 $end
    connect \D \result
    connect \Q {endpoint}
  end
{extra}
end
"""


class TracerTests(unittest.TestCase):
    def graph(self, text):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.il"
            path.write_text(text, encoding="utf-8")
            graph = Graph()
            with contextlib.redirect_stderr(io.StringIO()):
                graph.first_pass(path)
                graph.second_pass(path)
            return graph

    def trace(self, graph, src="^src$", to="^dst$"):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return graph.trace(src, to, 3)

    def test_two_gates_and_constants(self):
        graph = self.graph(netlist())
        path = self.trace(graph)[0]
        self.assertEqual(path["source"], "src")
        self.assertEqual(path["endpoint"], "dst")
        self.assertEqual(path["gates"], 2)
        self.assertAlmostEqual(path["units"], 2.4, places=5)
        self.assertEqual(len(graph.ff_q), 1)  # constant-D sources are boundaries, not targets

    def test_concat_and_range_alias(self):
        graph = self.graph(netlist(extra=r"""
  connect \bus { \dst \src }
"""))
        self.assertEqual(graph.root(graph.bits(r"\bus [0]")[0]),
                         graph.root(graph.bits(r"\src")[0]))
        self.assertEqual(graph.root(graph.bits(r"\bus [1:1]")[0]),
                         graph.root(graph.bits(r"\dst")[0]))
        self.assertEqual(self.trace(graph)[0]["gates"], 2)

    def test_exact_endpoint_q_bit_resolves_d_boundary(self):
        graph = self.graph(netlist(extra=r"  connect \bus { \dst \src }"))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = graph.trace(None, None, 1, source_bit="src", target_bit="bus[1]")
        self.assertEqual(result[0]["endpoint"], "dst")
        self.assertEqual(result[0]["gates"], 2)

    def test_exact_endpoint_q_rejects_combinational_node(self):
        graph = self.graph(netlist())
        with self.assertRaisesRegex(ValueError, "No matching FFs"):
            graph.trace(None, None, 1, source_bit="src", target_bit="middle")

    def test_register_boundary_is_not_crossed(self):
        gates = r"""
  cell $_NOT_ $first
    connect \A \src
    connect \Y \middle
  end
  cell \DFF_X1 $cut
    connect \D \middle
    connect \Q \other_dst
  end
  cell $_NOT_ $last
    connect \A \other_dst
    connect \Y \result
  end
"""
        graph = self.graph(netlist(gates=gates))
        with self.assertRaisesRegex(ValueError, "No combinational source"):
            self.trace(graph)
        self.assertEqual(self.trace(graph, "^other_dst$")[0]["gates"], 1)

    def test_mux_select_is_a_path(self):
        graph = self.graph(netlist())
        path = self.trace(graph, "^other$")[0]
        self.assertEqual(path["source"], "other")
        self.assertAlmostEqual(path["units"], 2.6, places=5)  # other drives two pins

    def test_unknown_cell_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsupported cell type"):
            self.graph(netlist().replace("$_AND_", "$mystery"))

    def test_memory_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Memory object"):
            self.graph(netlist(extra="  memory width 32 size 16 \\array"))

    def test_multiple_drivers_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Multiple"):
            self.graph(netlist(extra=r"""
  cell $_NOT_ $duplicate
    connect \A \other
    connect \Y \result
  end
"""))

    def test_cycle_is_rejected(self):
        graph = self.graph(netlist(gates=r"""
  cell $_AND_ $cycle_a
    connect \A \result
    connect \B \src
    connect \Y \middle
  end
  cell $_NOT_ $cycle_b
    connect \A \middle
    connect \Y \result
  end
"""))
        with self.assertRaisesRegex(ValueError, "Combinational cycle"):
            self.trace(graph)

    def test_bad_alias_width_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Alias width mismatch"):
            self.graph(netlist(extra=r"  connect \bus \src"))

    def test_multiple_modules_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one flattened"):
            self.graph(netlist() + "module \\second\nend\n")

    def test_primary_input_requires_explicit_scope(self):
        text = netlist().replace("wire \\src", "wire input 1 \\src")
        text = text.replace("  cell \\DFF_X1 $source\n    connect \\D 1'0\n    connect \\Q \\src\n  end", "")
        graph = self.graph(text)
        with self.assertRaisesRegex(ValueError, "No matching FFs"):
            self.trace(graph)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = graph.trace(None, "^dst$", 1, source_bit="src", source_kind="input")
        self.assertEqual(result[0]["gates"], 2)

    def test_exact_internal_signal_and_ff_d(self):
        graph = self.graph(netlist())
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            direct = graph.trace(None, None, 1, source_bit="src", target_node="middle")
            boundary = graph.trace(None, None, 1, source_bit="src", target_node="result")
        self.assertEqual(direct[0]["gates"], 1)
        self.assertEqual(boundary[0]["endpoint"], "dst")

    def test_exact_bit_bounds(self):
        graph = self.graph(netlist())
        with self.assertRaisesRegex(ValueError, "Bit outside"):
            graph.exact("bus[2]")
        with self.assertRaisesRegex(ValueError, "Wire not found"):
            graph.exact("absent")

    def test_details_are_opt_in_and_show_mux_data_pin(self):
        graph = self.graph(netlist())
        plain = self.trace(graph)[0]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            detailed = graph.trace("^src$", "^dst$", 1, details=True)[0]
        self.assertNotIn("primitive_nodes", plain)
        self.assertEqual(plain["units"], detailed["units"])
        nodes = detailed["primitive_nodes"]
        self.assertEqual(len(nodes), detailed["gates"]+1)
        self.assertEqual([n["kind"] for n in nodes], ["FF", "$_MUX_", "$_AND_"])
        self.assertEqual(nodes[1]["via_pins"], ["A"])
        self.assertEqual(nodes[2]["via_pins"], ["A"])
        self.assertTrue(all(n["fanout"] >= 0 for n in nodes))

    def test_details_show_mux_selector_pin(self):
        graph = self.graph(netlist())
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            detailed = graph.trace("^other$", "^dst$", 1, details=True)[0]
        self.assertEqual(detailed["primitive_nodes"][1]["via_pins"], ["S"])


if __name__ == "__main__":
    unittest.main()
