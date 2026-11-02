import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('panel_analysis', Path(__file__).with_name('analyze-panel-animation.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PanelAnalysisTests(unittest.TestCase):
    def test_timer_gap_crossing_transition_start_is_included(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'events.csv').write_text('host_time,event\n1.0,open-0\n')
            (root / 'ticks.csv').write_text('host_time\n0.99\n1.17\n1.19\n')
            (root / 'layouts.csv').write_text('host_time,duration_ms\n1.18,2\n')
            (root / 'frames.csv').write_text('time,status,edge,blackpixels\n0.99,0,31,32\n1.17,0,100,100\n1.20,0,200,200\n1.23,0,300,300\n')
            result = module.analyze(root)['summary']['open']
            self.assertAlmostEqual(result['max_main_timer_gap_ms'], 180)
            self.assertAlmostEqual(result['median_first_visible_change_ms'], 170)

    def test_static_frames_are_not_reported_as_animation_fps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'events.csv').write_text('host_time,event\n1.0,open-0\n')
            (root / 'ticks.csv').write_text('host_time\n0.99\n1.01\n')
            (root / 'layouts.csv').write_text('host_time,duration_ms\n')
            (root / 'frames.csv').write_text('time,status,edge,blackpixels\n0.99,0,31,32\n1.17,0,31,32\n1.20,0,31,32\n')
            self.assertEqual(module.analyze(root)['summary'], {})


if __name__ == '__main__':
    unittest.main()
