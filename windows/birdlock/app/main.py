"""Entry point of the BirdLock desktop app (Windows build; also runs on macOS for development)."""
from __future__ import annotations

import os
import sys


def _redirect_output(name: str):
    """Windowed builds have no console: send prints to a log file in the data folder."""
    from ..core.paths import data_dir
    path = data_dir()/name
    if name == 'app.log' and path.exists():
        path.replace(path.with_suffix('.log.1'))
    log = open(path, "w", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = log


def main():
    from ..core import log as _log
    _log.setup()
    if len(sys.argv) > 1 and sys.argv[1] == "--subject-regression":
        if not os.environ.get("BIRDLOCK_DATA"):
            raise SystemExit("Subject regression requires a disposable BIRDLOCK_DATA directory")
        _redirect_output("subject-regression.log")
        try:
            from .subject_regression import main as subject_regression
            subject_regression(sys.argv[2:])
        except Exception:
            import traceback
            traceback.print_exc()
            raise SystemExit(1)
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--project-regression":
        if not os.environ.get("BIRDLOCK_DATA"):
            raise SystemExit("Project regression requires a disposable BIRDLOCK_DATA directory")
        _redirect_output("project-regression.log")
        try:
            from .project_regression import main as project_regression
            project_regression(sys.argv[2:])
        except Exception:
            import traceback
            traceback.print_exc()
            raise SystemExit(1)
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--gui-regression":
        _redirect_output("regression.log")
        try:
            from .regression import main as regression
            regression(sys.argv[2:])
        except Exception:
            import traceback
            traceback.print_exc()
            raise SystemExit(1)
        return
    if "--selftest" in sys.argv:          # used by CI on the packaged exe
        _redirect_output("selftest.log")
        from ..cli import main as cli
        cli(["selftest"])
        return
    if "--smoketest" in sys.argv:
        os.environ["QT_QPA_PLATFORM"] = "offscreen"
        _redirect_output("smoketest.log")
    from ..core import log as _log
    _log.setup()
    if sys.stdout is None or sys.stderr is None:   # windowed exe (pythonw / PyInstaller noconsole)
        _redirect_output("app.log")
    # quieter ONNX Runtime logs, crisp rendering on high-DPI screens
    os.environ.setdefault("ORT_LOG_SEVERITY_LEVEL", "3")
    os.environ.setdefault("QT_ENABLE_HIGHDPI_SCALING", "1")
    from PySide6.QtCore import Qt, QTimer
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import QApplication

    try:
        import onnxruntime as ort
        ort.set_default_logger_severity(3)
    except Exception:
        pass

    from . import theme
    from .main_window import AGREEMENT_VERSION, AgreementDialog, MainWindow
    from .state import AppState
    from .. import APP_NAME
    from ..core.paths import resource_dir

    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setApplicationName("BirdLock")
    app.setApplicationDisplayName(APP_NAME)
    icon = resource_dir() / "assets" / "BirdLock.ico"
    if icon.exists():
        app.setWindowIcon(QIcon(str(icon)))
    theme.apply(app)
    if "--smoketest" in sys.argv and os.name == "nt":
        # the offscreen platform has no font database: load Microsoft YaHei for the screenshot
        from PySide6.QtGui import QFont, QFontDatabase
        fid = QFontDatabase.addApplicationFont(os.path.join(os.environ.get("WINDIR", "C:\\Windows"), "Fonts", "msyh.ttc"))
        fams = QFontDatabase.applicationFontFamilies(fid)
        if fams:
            app.setFont(QFont(fams[0], 9))

    def qt_messages(mode, ctx, msg):
        if "propagateSizeHints" not in msg and "font family" not in msg:
            _log.log.warning("Qt: %s", msg)
    from PySide6.QtCore import qInstallMessageHandler
    qInstallMessageHandler(qt_messages)
    state = AppState()
    win = MainWindow(state)
    win.show()

    paths = [p for p in sys.argv[1:] if not p.startswith("-") and os.path.exists(p)]

    if "--smoketest" in sys.argv:
        from ..core.paths import data_dir

        def snap():
            win.resize(1360, 860)
            win.grab().save(str(data_dir() / "smoketest.png"))
            print("smoketest ok", flush=True)
            app.quit()
        QTimer.singleShot(1500, snap)
        sys.exit(app.exec())

    def start():
        if state.agreement_accepted != AGREEMENT_VERSION:
            if AgreementDialog(win).exec() != AgreementDialog.Accepted:
                app.quit()
                return
            state.agreement_accepted = AGREEMENT_VERSION
            state._save_settings_now()
        if paths:
            win.open_paths(paths)

    QTimer.singleShot(0, start)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
