import os
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from birdlock.core import frames, video_import, workspace
from birdlock.core.edit_history import EditHistory, EditState
from birdlock.core.settings import AudioTrack
from test_workspace import example


class NextReleaseTests(unittest.TestCase):
    def test_group_and_track_state_round_trips_with_legacy_defaults(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            doc = example(root / "原片")
            doc["segments"][0]["name"] = "同名 · ☘ / Nest"
            group_id = doc["segments"][0]["groupID"]
            doc["audio"]["tracks"] = [
                dict(assetID="sony-20", enabled=False, volume=.4, timelineStart=2, loop=True, fadeIn=.25),
                dict(assetID="single-canon-rebel", volume=.7),
            ]
            path = root / "工程.birdlock"
            workspace.save(doc, path, root / "cache")
            loaded = workspace.restore_media(workspace.read(path), root / "cache")
            group = frames.BurstSegment.from_project(loaded["segments"][0])
            self.assertEqual((group.groupID, group.name), (group_id, "同名 · ☘ / Nest"))
            self.assertEqual(frames.BurstSegment.from_project(dict(start=0, count=6, fps=30)).groupID, "legacy-0-6")
            audio = workspace.local_audio(loaded["audio"])
            self.assertFalse(audio.tracks[0].enabled)
            self.assertTrue(audio.tracks[1].enabled)
            self.assertEqual([t.assetID for t in audio.arranged_tracks], ["single-canon-rebel"])
            audio.tracks[0].enabled = True
            self.assertEqual(len(audio.arranged_tracks), 2)
            self.assertEqual((audio.tracks[0].volume, audio.tracks[0].timelineStart, audio.tracks[0].loop, audio.tracks[0].fadeIn),
                             (.4, 2, True, .25))
            self.assertFalse(AudioTrack(assetID="sony-20", muted=True).active)

    def test_3200_photos_form_20_bursts_and_cancel(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            when = datetime(2024, 1, 1)
            for group in range(20):
                path = root / f"{group:02d}_000.jpg"
                image = Image.new("RGB", (24, 16))
                exif = image.getexif()
                exif[0x0132] = (when + timedelta(seconds=10 * group)).strftime("%Y:%m:%d %H:%M:%S")
                image.save(path, exif=exif)
                for i in range(1, 160):
                    os.link(path, root / f"{group:02d}_{i:03d}.jpg")
            calls = []
            media = frames.import_frames([str(root)], progress=lambda n, total: calls.append((n, total)))
            self.assertEqual(len(media), 3200)
            groups = frames.segments(media)
            self.assertEqual([g.stop - g.start for g in groups], [160] * 20)
            self.assertEqual(len({g.groupID for g in groups}), 20)
            self.assertEqual(calls[-1], (3200, 3200))
            calls.clear()
            with self.assertRaises(frames.PhotoImportCancelled):
                frames.import_frames([str(root)], progress=lambda n, total: calls.append(n), cancelled=lambda: bool(calls))

    def test_history_groups_drag_branches_and_caps(self):
        history = EditHistory(2)
        state = lambda n: EditState(n, n)
        history.reset(state(0))
        history.begin()
        history.update(state(1))
        history.update(state(2))
        history.end()
        history.update(state(3))
        self.assertEqual((history.step(), history.step(), history.step(True)), (2, 0, 2))
        history.update(state(4))
        self.assertIsNone(history.step(True))
        history.update(state(5))
        self.assertEqual((history.step(), history.step(), history.step()), (4, 2, None))

    def test_long_import_boundaries_and_disk_budget(self):
        info = video_import.VideoInfo(1920, 1080, 60, 630)
        self.assertEqual(video_import.selection(info, 0, 600, 30)[-1], 18000)
        with self.assertRaises(ValueError):
            video_import.selection(info, 0, 601, 30)
        with self.assertRaises(ValueError):
            video_import.selection(info, 0, 600, 31)
        with tempfile.TemporaryDirectory() as td, patch.object(video_import.shutil, "disk_usage") as disk:
            disk.return_value.free = 1
            with self.assertRaises(ValueError):
                video_import.check_cache_budget(info, 600, 18000, Path(td))
