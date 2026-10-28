"""Diagnostic log: data/birdlock.log (errors, native crashes, key events). Attach it when reporting a problem."""
from __future__ import annotations

import faulthandler
import logging
import logging.handlers
import platform
import sys
import threading
import atexit
import os

log = logging.getLogger("birdlock")
_fault_file = None


def setup():
    from .paths import data_dir
    from .. import __version__
    global _fault_file
    if _fault_file is not None:
        return
    root = data_dir()
    marker = root/'running-session'
    if marker.exists():
        (root/'previous-exit-unexpected').touch()
    else:
        (root/'previous-exit-unexpected').unlink(missing_ok=True)
    marker.write_text(str(os.getpid()))
    def normal_exit():
        log.info("normal exit")
        marker.unlink(missing_ok=True)
    atexit.register(normal_exit)
    path = data_dir() / "birdlock.log"
    h = logging.handlers.RotatingFileHandler(path, maxBytes=2 << 20, backupCount=2, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s [%(threadName)s] %(message)s"))
    log.addHandler(h)
    log.setLevel(logging.INFO)
    # native crashes (access violations in GPU drivers etc.) dump all thread stacks here
    crash = root/'crash.log'
    if crash.exists() and crash.stat().st_size > 2<<20:
        crash.replace(root/'crash.log.1')
    _fault_file = open(crash, "a", encoding="utf-8")
    faulthandler.enable(_fault_file, all_threads=True)

    def excepthook(t, v, tb):
        log.critical("unhandled exception", exc_info=(t, v, tb))
        sys.__excepthook__(t, v, tb)

    def thread_hook(args):
        log.error("exception in thread %s", args.thread.name if args.thread else "?",
                  exc_info=(args.exc_type, args.exc_value, args.exc_traceback))

    sys.excepthook = excepthook
    threading.excepthook = thread_hook
    log.info("BirdLock %s on %s %s, Python %s", __version__, platform.system(), platform.version(), platform.python_version())
    log.info("previous_exit_unexpected=%s", (root/'previous-exit-unexpected').exists())
