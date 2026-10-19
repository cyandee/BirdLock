import threading
import unittest

from birdlock.app.state import LatestOnly


class ShutdownTests(unittest.TestCase):
    def test_close_releases_idle_worker(self):
        worker = LatestOnly("test-idle-preview")
        worker.close()
        worker._thread.join(timeout=1)
        self.assertFalse(worker._thread.is_alive())

    def test_close_discards_pending_and_future_jobs(self):
        started, release = threading.Event(), threading.Event()
        seen = []
        worker = LatestOnly("test-running-preview")

        def current():
            started.set()
            release.wait(timeout=2)

        try:
            worker.submit(current)
            self.assertTrue(started.wait(timeout=1))
            worker.submit(lambda: seen.append("pending"))
            worker.close()
            worker.submit(lambda: seen.append("late"))
        finally:
            release.set()
            worker.close()
            worker._thread.join(timeout=1)
        self.assertFalse(worker._thread.is_alive())
        self.assertEqual(seen, [])
