import math
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
from birdlock.core.analysis import Box, FrameAnalysis
from birdlock.core.planner import FrameXform
from birdlock.core.render import RenderJob, OutputFrame, output_frames
from birdlock.core.settings import ExportSettings, FocusMarkSettings, FocusMarkColor


class FocusTests(unittest.TestCase):
    def test_colors_migrate_and_remain_independent(self):
        settings = FocusMarkSettings.from_dict({"color": "orange", "size": 1.8})
        self.assertEqual(settings.eyeColor, FocusMarkColor.ORANGE)
        self.assertEqual(settings.headColor, FocusMarkColor.ORANGE)
        self.assertEqual(settings.bodyColor, FocusMarkColor.ORANGE)
        self.assertEqual(settings.bodySize, 1.8)
        settings.eyeColor, settings.headColor, settings.bodyColor = FocusMarkColor.WHITE, FocusMarkColor.BLACK, FocusMarkColor.GREEN
        restored = FocusMarkSettings.from_dict(settings.to_dict())
        self.assertEqual([restored.color_for(t) for t in ("eye", "head", "body")],
                         [FocusMarkColor.WHITE, FocusMarkColor.BLACK, FocusMarkColor.GREEN])

    def test_120_hz_is_not_clamped_to_15(self):
        settings = FocusMarkSettings(flashRate=120)
        self.assertTrue(settings.flash_on(0))
        self.assertFalse(settings.flash_on(1 / 240))
        self.assertTrue(settings.flash_on(1 / 120))

    def render_stub(self):
        job = RenderJob.__new__(RenderJob)
        job.export = ExportSettings()
        job.contains = lambda _: True
        job.compose = lambda *args: np.full((200, 200, 3), 127, np.uint8)
        job._text_overlay = lambda *args: None
        job.watermark_image = lambda: None
        job.focus_rect = lambda i, target, scale: np.array([100, 100, 30, 40])
        return job

    def test_each_rendered_target_uses_its_own_color(self):
        job = self.render_stub()
        fm = job.export.focusMark
        fm.enabled = fm.showEye = fm.showHead = fm.showBody = True
        fm.eyeColor, fm.headColor, fm.bodyColor = FocusMarkColor.WHITE, FocusMarkColor.ORANGE, FocusMarkColor.GREEN
        with patch("birdlock.core.render.draw_focus_mark") as draw:
            job.render_output(OutputFrame(0, 0, 0, 1), fetch=lambda _: (None, 1))
        self.assertEqual([call.args[5] for call in draw.call_args_list],
                         [fm.eyeColor.bgr, fm.headColor.bgr, fm.bodyColor.bgr])

    def test_capture_size_color_and_120hz_reach_rendered_pixels(self):
        job = self.render_stub()
        fm = job.export.focusMark
        fm.captureFlash, fm.captureSize, fm.captureColor, fm.flashRate = True, 0.5, FocusMarkColor.WHITE, 120
        image = job.render_output(OutputFrame(0, 0, 0, 1, time=0), fetch=lambda _: (None, 1))
        self.assertGreater(int(image[50, 50, 0]), 170)
        np.testing.assert_array_equal(image[30, 50], [127, 127, 127])
        np.testing.assert_array_equal(image[100, 100], [127, 127, 127])
        off = job.render_output(OutputFrame(0, 0, 0, 1, time=1 / 240), fetch=lambda _: (None, 1))
        self.assertTrue(np.all(off == 127))

    def test_old_settings_preserve_appearance(self):
        s = FocusMarkSettings.from_dict({"enabled": True})
        self.assertTrue(s.showEye)
        self.assertFalse(s.showBody or s.showHead or s.captureFlash)

    def test_repeat_frames_have_distinct_effect_times(self):
        frames = output_frames([0, 1], 1, ExportSettings(outputFPS=30))
        self.assertEqual(frames[1].a, frames[2].a)
        self.assertAlmostEqual(frames[1].time, 1 / 30)
        self.assertAlmostEqual(frames[2].time, 2 / 30)

    def test_rotated_body_box_contains_all_wing_corners(self):
        xf = FrameXform(np.array([700, 300]), np.array([200, 250]), 0.6, math.radians(35), True)
        box = Box(150, 200, 700, 220, 0.9)
        job = RenderJob.__new__(RenderJob)
        job.export = ExportSettings()
        job.analysis = SimpleNamespace(count=1, perFrame=[FrameAnalysis(0, [box], 0)])
        job.track = SimpleNamespace(has_data=[True])
        job.plan = SimpleNamespace(xforms=[xf])
        rect = job.focus_rect(0, "body", 0.5)
        job.export.focusMark.size = 2.5
        np.testing.assert_allclose(job.focus_rect(0, "body", 0.5), rect)
        job.export.focusMark.bodySize = 0.5
        small = job.focus_rect(0, "body", 0.5)
        np.testing.assert_allclose(small[:2], rect[:2])
        np.testing.assert_allclose(small[2:], rect[2:] * 0.5)
        lo, hi = rect[:2] - rect[2:] / 2, rect[:2] + rect[2:] / 2
        for p in [(150, 200), (850, 200), (150, 420), (850, 420)]:
            q = xf.scaled(0.5).map(p)
            self.assertTrue(np.all(q >= lo) and np.all(q <= hi))


if __name__ == "__main__":
    unittest.main()
