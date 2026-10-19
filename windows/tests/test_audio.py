import json
import os
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

from birdlock.core.exporter import ExportError, _audio_plan, render_audio_preview
from birdlock.core.paths import ffmpeg_path
from birdlock.core.settings import AudioSettings, AudioTrack
from birdlock.core.sounds import assets, asset_path


class AudioTests(unittest.TestCase):
    def test_old_music_and_independent_tracks_round_trip(self):
        old = AudioSettings.from_dict({"path": "music.wav", "volume": 0.7})
        self.assertEqual(old.tracks, [])
        old.tracks.append(AudioTrack(assetID="sony-10", timelineStart=0.25, muted=True))
        restored = AudioSettings.from_dict(json.loads(json.dumps(old.to_dict())))
        self.assertEqual(restored.tracks[0], old.tracks[0])
        self.assertEqual(restored.volume, 0.7)
        self.assertEqual(len(assets()), 12)
        self.assertTrue(Path(asset_path("sony-10")).is_file())

    @unittest.skipUnless(ffmpeg_path(), "FFmpeg required")
    def test_actual_mix_timing_mute_trim_and_silent_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "tone.wav")
            with wave.open(path, "wb") as w:
                w.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
                w.writeframes(np.full(19200, round(0.4 * 32767), dtype="<i2").tobytes())
            track = AudioTrack(path=path, volume=1, loop=False, fadeIn=0, fadeOut=0)
            second = track.copy()
            second.timelineStart = 0.4
            muted = track.copy()
            muted.muted = True
            settings = AudioSettings(tracks=[track, second, muted])
            result = render_audio_preview(settings, 1)
            self.addCleanup(lambda: os.path.exists(result) and os.unlink(result))
            with wave.open(result, "rb") as w:
                self.assertEqual(w.getframerate(), 48000)
                samples = np.frombuffer(w.readframes(w.getnframes()), "<i2").reshape(-1, 2) / 32768
            self.assertAlmostEqual(len(samples) / 48000, 1, places=3)
            for time, expected in [(0.05, 0.2), (0.3, 0), (0.45, 0.2), (0.8, 0)]:
                self.assertAlmostEqual(float(samples[round(time * 48000), 0]), expected, delta=0.002, msg=f"at {time}s")
            preview = render_audio_preview(settings, 1, start=0.4)
            self.addCleanup(lambda: os.path.exists(preview) and os.unlink(preview))
            with wave.open(preview, "rb") as w:
                self.assertAlmostEqual(w.getnframes() / w.getframerate(), 0.6, places=3)

    def test_missing_active_sound_is_not_silently_dropped(self):
        with self.assertRaises(ExportError):
            _audio_plan(AudioSettings(tracks=[AudioTrack(assetID="missing")]), 1)

    @unittest.skipUnless(ffmpeg_path(), "FFmpeg required")
    def test_short_sources_keep_delays_with_mixed_rates_and_offsets_after_eof(self):
        with tempfile.TemporaryDirectory() as directory:
            def tone(name, rate, seconds, value):
                path = str(Path(directory) / name)
                with wave.open(path, "wb") as w:
                    w.setparams((2, 2, rate, 0, "NONE", "not compressed"))
                    w.writeframes(np.full(round(seconds*rate)*2, round(value*32767), dtype="<i2").tobytes())
                return path
            a = AudioTrack(path=tone("a.wav", 48000, .2, .4), loop=False, fadeIn=0, fadeOut=0)
            b = AudioTrack(path=tone("b.wav", 44100, .3, .2), startOffset=.1, timelineStart=.4,
                           loop=False, fadeIn=0, fadeOut=0)
            settings = AudioSettings(tracks=[a, b])
            # This was intermittent: one passing render did not establish correct timing.
            for iteration in range(20):
                result = render_audio_preview(settings, 1)
                self.addCleanup(lambda p=result: os.path.exists(p) and os.unlink(p))
                with wave.open(result, "rb") as w:
                    self.assertEqual(w.getnframes(), 48000)
                    samples = np.frombuffer(w.readframes(w.getnframes()), "<i2").reshape(-1, 2)/32768
                actual = samples[[2400, 14400, 21600, 38400], 0]
                np.testing.assert_allclose(actual, [.2, 0, .1, 0], atol=.002, err_msg=f"iteration {iteration}")

    def test_library_uses_original_recordings_and_valid_camera_variants(self):
        import hashlib
        from birdlock.core.sounds import cameras, burst_assets
        self.assertEqual(len(cameras()),5)
        self.assertEqual(len(burst_assets()),11)
        for entry in assets():
            data=Path(asset_path(entry["id"])).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(),entry["sha256"])
            self.assertGreater(entry["duration"],0)
        self.assertEqual([e["fps"] for e in burst_assets() if e["cameraID"]=="sony-a7m5"],[30,15])
        self.assertEqual(next(e["fps"] for e in assets() if e["id"]=="nikon-z8"),20)
        self.assertEqual(asset_path("sony-20"),asset_path("sony-a1m2-30"))
