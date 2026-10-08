"""Regression for mapped DFF Q/QN structural start/end boundaries."""
from pathlib import Path
import unittest

from trace_full_array_path import Graph


class TestFfOutputs(unittest.TestCase):
    def test_both_polarities(self):
        root=Path(__file__).absolute().parent.parent
        fixture=root/'out/trace_ff_outputs_fixture.il'
        fixture.parent.mkdir(parents=True,exist_ok=True)
        fixture.write_text(r'''module \trace_ff_fixture
  wire input 1 \clk
  wire input 2 \data
  wire input 3 \gate
  wire \q
  wire \qn
  wire \next
  wire \dest
  wire \destn
  cell \DFF_X1 \source
    connect \CK \clk
    connect \D \data
    connect \Q \q
    connect \QN \qn
  end
  cell $_AND_ \logic
    connect \A \qn
    connect \B \gate
    connect \Y \next
  end
  cell \DFF_X1 \sink
    connect \CK \clk
    connect \D \next
    connect \Q \dest
    connect \QN \destn
  end
end
''',encoding='utf-8')
        graph=Graph()
        graph.first_pass(fixture)
        graph.second_pass(fixture)
        for name in ('q','qn','dest','destn'):
            self.assertTrue(graph.register[graph.exact(name)])
        for target in ('dest','destn'):
            paths=graph.trace(None,None,1,'qn',None,'ff',target,False)
            self.assertEqual(paths[0]['gates'],1)
        # Q and QN share a physical FF's D; both are output boundaries.
        self.assertEqual(len(graph.ff_q),4)
        # The public Q name identifies the physical source FF. QN fanout
        # must not disappear from a register-regex query.
        paths=graph.trace('^q$','^dest$',1)
        self.assertEqual(paths[0]['gates'],1)
        # A specifically requested mapped PI is still pin-exact.
        with self.assertRaisesRegex(ValueError,'No combinational'):
            graph.trace(None,None,1,'q',None,'ff','dest',False)


if __name__=='__main__': unittest.main()
