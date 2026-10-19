import threading
import unittest

from birdlock.core.analysis import Cancelled
from birdlock.core.aircraft_analysis import _analysis_slot


class AircraftQueueTests(unittest.TestCase):
    def test_new_analysis_waits_and_can_cancel_without_entering_active_work(self):
        release,active,queued,finished = (threading.Event() for _ in range(4))
        cancel = threading.Event()
        errors,entered = [],[]
        def first():
            try:
                with _analysis_slot(lambda:False,None):
                    active.set()
                    if not release.wait(5):raise TimeoutError('Test holder was not released')
            except Exception as error:errors.append(error)
        def second():
            try:
                with _analysis_slot(cancel.is_set,lambda stage,p:queued.set()):
                    entered.append('unexpected second model')
            except Cancelled:pass
            except Exception as error:errors.append(error)
            finally:finished.set()
        holder=threading.Thread(target=first,daemon=True);holder.start()
        self.addCleanup(release.set)
        self.assertTrue(active.wait(2))
        follower=threading.Thread(target=second,daemon=True);follower.start()
        self.assertTrue(queued.wait(2))
        cancel.set();self.assertTrue(finished.wait(2))
        self.assertEqual(entered,[])
        release.set();holder.join(2);follower.join(2)
        self.assertFalse(holder.is_alive());self.assertFalse(follower.is_alive());self.assertEqual(errors,[])
        with _analysis_slot(lambda:False,None):entered.append('next model')
        self.assertEqual(entered,['next model'])

    def test_exception_releases_slot_for_next_request(self):
        with self.assertRaisesRegex(RuntimeError,'inference failed'):
            with _analysis_slot(lambda:False,None):raise RuntimeError('inference failed')
        stop=threading.Event();timer=threading.Timer(2,stop.set);timer.start()
        self.addCleanup(timer.cancel)
        with _analysis_slot(stop.is_set,None):pass
        self.assertFalse(stop.is_set())


if __name__ == '__main__':unittest.main()
