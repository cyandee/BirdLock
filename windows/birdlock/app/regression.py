"""Real-window regression for photo import, preview and the previously broken inspector tabs.

Run with a disposable BIRDLOCK_DATA directory. No offscreen platform is used.
"""
import argparse
import json
import time
from pathlib import Path

from PySide6.QtWidgets import QApplication
from birdlock.app import theme
from birdlock.app.main_window import MainWindow
from birdlock.app.state import AppState


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("photos")
    parser.add_argument("output", type=Path)
    parser.add_argument("--export", action="store_true", help="Also render H.264 and portrait HEVC")
    args = parser.parse_args(argv)
    args.output.mkdir(parents=True, exist_ok=True)
    app = QApplication([])
    theme.apply(app)
    state = AppState()
    state.device = "cpu"
    window = MainWindow(state)
    window.show()

    def until(condition, timeout=120):
        deadline = time.monotonic() + timeout
        while not condition():
            app.processEvents()
            if state.phase == "failed":
                raise RuntimeError(state.message)
            if time.monotonic() > deadline:
                raise TimeoutError("UI operation did not finish")
            time.sleep(0.01)

    def settle():
        end = time.monotonic() + 0.12
        while time.monotonic() < end:
            app.processEvents()
            time.sleep(0.005)

    state.import_paths([args.photos])
    until(lambda: state.phase == "ready" and state.job is not None)
    state.export.focusMark.enabled = True
    state.export.focusMark.showBody = True
    state.export.focusMark.showHead = True
    state.export.focusMark.captureFlash = True
    from birdlock.core.settings import AudioTrack, FocusMarkColor
    from birdlock.core.sounds import assets, asset_path
    assert len(assets()) == 12, "Missing bundled sound library"
    state.export.focusMark.eyeColor = FocusMarkColor.WHITE
    state.export.focusMark.headColor = FocusMarkColor.ORANGE
    state.export.focusMark.bodyColor = FocusMarkColor.GREEN
    state.export.focusMark.bodySize = 1.3
    state.export.focusMark.captureColor = FocusMarkColor.ORANGE
    state.export.focusMark.captureSize = 0.7
    state.export.focusMark.flashRate = 120
    state.set_audio(asset_path("nikon-z8"))
    state.audio.volume = 0.3
    state.audio.tracks = [AudioTrack(assetID="sony-20", timelineStart=0.1, duration=0.2, volume=0.5, fadeIn=0, fadeOut=0),
                          AudioTrack(assetID="sony-10", muted=True)]
    state.audio_settings_changed()
    state.settings_changed()
    settle()
    measurements = []
    for cycle in range(10):
        for width in (1100, 1360):
            window.resize(width, 860)
            for index in (2, 0, 1, 2):
                window.inspector.tabbar.setCurrentIndex(index)
                settle()
                tab = window.inspector.tabs[index]
                viewport, body = tab.viewport().width(), tab.widget().width()
                measurements.append([cycle, width, index, viewport, body])
                if body != viewport or tab.horizontalScrollBar().maximum() != 0:
                    raise AssertionError(f"Inspector overflow: {measurements[-1]}")
        state.step(1)
        settle()
    state.toggle_play()
    settle()
    state.stop()
    settle()
    window.grab().save(str(args.output / "ui-regression.png"))
    from birdlock.app.inspector import Card
    output_tab = window.inspector.tabs[2]
    for card in output_tab.widget().findChildren(Card):
        title = card.lay.itemAt(0).widget().text()
        for label, filename in (("对焦框", "focus-controls.png"), ("音效与多轨", "audio-controls.png")):
            if label in title:
                output_tab.verticalScrollBar().setValue(card.y())
                settle()
                window.grab().save(str(args.output / filename))
    output_tab.verticalScrollBar().setValue(0)
    result = {"photos": state.analysis.count, "cycles": 10, "layout_checks": len(measurements),
              "all_layout_checks_passed": True, "frames_rendered": state.preview_image is not None, "audio_tracks": len(state.audio.arranged_tracks),
              "sound_library": len(assets()), "flash_rate": state.export.focusMark.flashRate}
    if not result["frames_rendered"]:
        raise AssertionError("No preview frame was rendered")
    if args.export:
        from birdlock.core.exporter import VideoExporter
        from birdlock.core.render import RenderJob
        from birdlock.core.settings import AspectRatio, VideoCodec, FrameInterpolation
        result["exports"] = []
        for codec, short_side in ((VideoCodec.H264, 720), (VideoCodec.HEVC, 1440)):
            settings = state.export.copy()
            settings.codec = codec
            settings.shortSide = short_side
            settings.aspect = AspectRatio(9, 16, "9:16")
            settings.interpolation = FrameInterpolation.NEAREST
            job = RenderJob(state.analysis.copy_edits(), state.composition.copy(), state.look.copy(), settings,
                            state.selection.copy(), cache=state.cache)
            exporter = VideoExporter()
            output = args.output / f"{codec.value}-{short_side}.mp4"
            exporter.export_video(job, str(output), audio=state.audio.copy())
            result["exports"].append({"codec": codec.value, "size": list(job.output_size),
                                      "frames": len(job.output_frames), "encoder": exporter.encoder_used,
                                      "bytes": output.stat().st_size})
    (args.output / "ui-regression.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)
    window.close()


if __name__ == "__main__":
    main()
