"""Aircraft feasibility module invariants; no weights, downloads or product-mode activation."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import cv2
import numpy as np

from birdlock.core.aircraft import (AircraftCancelled, AircraftPartsModel, NoseCandidate, NoseObservation, NoseImageTracker,
                                   choose_consensus, verify_model)
from birdlock.core.models import Detection


class AircraftTests(unittest.TestCase):
    def test_image_tracker_refines_imperfect_body_motion_and_rejects_blank_occlusion(self):
        rng = np.random.default_rng(20261018)
        image = cv2.GaussianBlur(rng.integers(0, 256, (240, 320), dtype=np.uint8), (3, 3), .7)
        moved = cv2.warpAffine(image, np.float32([[1, 0, 3.25], [0, 1, -1.5]]), (320, 240))
        body = Detection(60, 50, 160, 120, .9)
        imperfect = Detection(64.6, 47.8, 160, 120, .9)
        nose = NoseObservation(110, 103, 20, 14, .6, 3)
        tracker = NoseImageTracker()
        result = tracker.step(image, moved, nose, body, imperfect)
        self.assertIsNotNone(result)
        np.testing.assert_allclose(result.nose.center, nose.center+[3.25, -1.5], atol=.3)
        self.assertEqual(result.nose.views, 0)
        self.assertGreater(result.registration_quality, 12)
        self.assertIsNone(tracker.step(image, np.full_like(image, 127), nose, body, imperfect))

    def test_candidates_need_independent_views_and_never_fall_back_to_body_center(self):
        body = Detection(0, 0, 200, 100, .9)
        duplicate = [NoseCandidate(0, .8, 20+i, 30, 20, 15) for i in range(5)]
        self.assertIsNone(choose_consensus(duplicate, body))
        self.assertIsNone(choose_consensus([], body))
        agreed = choose_consensus(duplicate + [NoseCandidate(90, .7, 22, 32, 18, 16)], body)
        self.assertIsNotNone(agreed)
        self.assertEqual(agreed.views, 2)
        np.testing.assert_allclose(agreed.center, [20.933333, 30.933333], atol=1e-5)
        self.assertGreater(np.linalg.norm(agreed.center-[100, 50]), 70)

    def test_noisy_body_box_does_not_move_or_rescale_an_image_tracked_nose(self):
        rng = np.random.default_rng(20261018)
        image = cv2.GaussianBlur(rng.integers(0,256,(240,320),dtype=np.uint8),(3,3),.7)
        moved = cv2.warpAffine(image,np.float32([[1,0,1.3],[0,1,-.7]]),(320,240))
        nose = NoseObservation(110.27,103.31,20,14,.6,3)
        result = NoseImageTracker().step(image,moved,nose,Detection(60,50,160,120,.9),Detection(120,40,120,140,.9))
        self.assertIsNotNone(result)
        np.testing.assert_allclose(result.nose.center,nose.center+[1.3,-.7],atol=.3)
        self.assertEqual((result.nose.w,result.nose.h),(20,14))

    def test_nonfinite_and_disagreeing_parts_do_not_become_observations(self):
        body = Detection(0, 0, 200, 100, .9)
        self.assertIsNone(choose_consensus([NoseCandidate(0, .8, 20, 30, 20, 15),
                                           NoseCandidate(90, .9, 180, 90, 20, 15)], body))
        self.assertIsNone(choose_consensus([NoseCandidate(0, .8, float("nan"), 30, 20, 15),
                                           NoseCandidate(90, .9, 20, 30, 20, 15)], body))

    def test_verification_refuses_corrupt_or_redirected_weights_without_changing_them(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "part.onnx"
            path.write_bytes(b"test-model")
            meta = dict(file=path.name, bytes=10, sha256=hashlib.sha256(b"test-model").hexdigest())
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(meta))
            self.assertEqual(verify_model(root), meta)
            path.write_bytes(b"bad!-model")
            with self.assertRaisesRegex(ValueError, "校验失败"):
                verify_model(root)
            self.assertEqual(path.read_bytes(), b"bad!-model")
            meta["file"] = "../part.onnx"
            manifest.write_text(json.dumps(meta))
            with self.assertRaisesRegex(ValueError, "文件名无效"):
                verify_model(root)

    def test_cancelled_and_invalid_requests_do_not_allocate_the_model(self):
        model = AircraftPartsModel(directory=Path("uninstalled-aircraft-model"))
        image = np.zeros((40, 40, 3), np.uint8)
        with self.assertRaises(AircraftCancelled):
            model.detect(image, Detection(5, 5, 20, 20, .9), cancelled=lambda: True)
        self.assertIsNone(model.detect(image, Detection(500, 500, 20, 20, .9)))
        self.assertIsNone(model.detect(image, Detection(0, 0, float("nan"), 20, .9)))
        self.assertIsNone(model._session)

    def fake_model(self, session):
        model = AircraftPartsModel()
        model._session = session
        manifest = Path(__file__).resolve().parents[2] / "SharedResources/AircraftModels/manifest.json"
        model._meta = json.loads(manifest.read_text(encoding="utf-8"))
        return model

    def test_whole_aircraft_outputs_are_rejected_even_with_four_high_scores(self):
        class FullBodySession:
            def run(self, names, inputs):
                logits = np.full((1, 900, 256), -20, np.float32)
                logits[0, 0, 2] = 5
                boxes = np.zeros((1, 900, 4), np.float32)
                boxes[0, 0] = [.5, .5, .85, .85]
                return logits, boxes
        model = self.fake_model(FullBodySession())
        self.assertIsNone(model.detect(np.zeros((40, 40, 3), np.uint8), Detection(10, 10, 20, 20, .9)))

    def test_cancellation_is_checked_after_each_runtime_call(self):
        class Session:
            calls = 0
            def run(self, names, inputs):
                self.calls += 1
                return np.zeros((1, 900, 256), np.float32), np.zeros((1, 900, 4), np.float32)
        session = Session()
        model = self.fake_model(session)
        with self.assertRaises(AircraftCancelled):
            model.detect(np.zeros((40, 40, 3), np.uint8), Detection(10, 10, 20, 20, .9),
                         cancelled=lambda: session.calls > 0)
        self.assertEqual(session.calls, 1)

    def test_oversized_proxy_and_invalid_backend_outputs_are_rejected(self):
        model = AircraftPartsModel(directory=Path("uninstalled-aircraft-model"))
        with self.assertRaisesRegex(ValueError, "尺寸超出范围"):
            model.detect(np.zeros((1, 4097, 3), np.uint8), Detection(0, 0, 4097, 1, .9))
        self.assertIsNone(model._session)
        for malformed in (True, False):
            class Session:
                def run(self, names, inputs):
                    return (np.zeros((1, 2, 256), np.float32) if malformed else np.full((1, 900, 256), np.nan, np.float32),
                            np.zeros((1, 900, 4), np.float32))
            with self.assertRaisesRegex(ValueError, "输出"):
                self.fake_model(Session()).detect(np.zeros((40, 40, 3), np.uint8), Detection(10, 10, 20, 20, .9))


if __name__ == "__main__":
    unittest.main()
