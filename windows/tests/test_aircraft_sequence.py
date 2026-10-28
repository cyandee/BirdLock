"""Sequence scheduling and real pixel tracking, without downloading or loading aircraft weights."""
import unittest
from unittest.mock import patch

import cv2
import numpy as np

from birdlock.core.aircraft import AircraftCancelled, AircraftPartsModel, NoseObservation
from birdlock.core.aircraft_sequence import analyze_aircraft_noses
from birdlock.core.models import Detection


class AircraftSequenceTests(unittest.TestCase):
    def texture(self, seed):
        rng = np.random.default_rng(seed)
        return cv2.GaussianBlur(rng.integers(0, 256, (240, 320, 3), dtype=np.uint8), (3, 3), .7)

    def test_separate_bursts_seed_independently_and_track_pixels_both_directions(self):
        images, bodies, truths = [], [], []
        for group in range(2):
            base = self.texture(20261018+group)
            for j in range(8):
                dx, dy = j*1.3, j*(-.7)
                images.append(cv2.warpAffine(base, np.float32([[1, 0, dx], [0, 1, dy]]), (320, 240)))
                bodies.append(Detection(60+dx, 50+dy, 160, 120, .95 if j == 4 else .8))
                truths.append(NoseObservation(110+dx, 103+dy, 20, 14, .6, 3))
        class Model:
            calls = []
            def detect(self, image, body, **kwargs):
                index = next(i for i, value in enumerate(bodies) if value is body)
                self.calls.append(index)
                kwargs['progress'](1)
                return truths[index]
        model = Model()
        reads, progress = [], []
        def read(i):
            reads.append(i)
            return images[i]
        result = analyze_aircraft_noses(bodies, read, model=model, refresh_interval=100,
                                        clips=[dict(start=0, count=8), dict(start=8, count=8)], progress=progress.append)
        self.assertEqual(model.calls, [4, 12])
        self.assertEqual(sorted(reads), list(range(16)))
        self.assertEqual([i for i, value in enumerate(result) if value.source == 'detected'], [4, 12])
        for actual, expected in zip(result, truths):
            self.assertIsNotNone(actual.nose)
            np.testing.assert_allclose(actual.nose.center, expected.center, atol=.45)
            if actual.source == 'tracked':
                self.assertEqual(actual.nose.views, 0)
                self.assertGreater(actual.registration_quality, 12)
        self.assertEqual(progress[-1], 1)
        self.assertTrue(all(a <= b for a, b in zip(progress, progress[1:])))

    def test_failed_semantic_refresh_leaves_gap_and_retries_without_stale_prediction(self):
        image = self.texture(17)
        bodies = [Detection(60, 50, 160, 120, 1 if i == 0 else .8) for i in range(8)]
        nose = NoseObservation(110, 103, 20, 14, .6, 3)
        class Model:
            calls = []
            def detect(self, image, body, **kwargs):
                index = next(i for i, value in enumerate(bodies) if value is body)
                self.calls.append(index)
                return None if index == 3 else nose
        model = Model()
        result = analyze_aircraft_noses(bodies, lambda i: image, model=model, refresh_interval=3, retry_interval=2)
        self.assertEqual(model.calls, [0, 3, 5])
        self.assertEqual([r.source for r in result], ['detected', 'tracked', 'tracked', 'missing', 'missing', 'detected', 'tracked', 'tracked'])
        self.assertIsNone(result[3].nose)
        self.assertIsNone(result[4].nose)

    def test_blank_occlusion_is_not_bridged_by_body_motion(self):
        image = self.texture(19)
        bodies = [Detection(60, 50, 160, 120, 1 if i == 0 else .8) for i in range(6)]
        class Model:
            def detect(self, image, body, **kwargs):
                return None if image.var() == 0 else NoseObservation(110, 103, 20, 14, .6, 3)
        result = analyze_aircraft_noses(bodies, lambda i: np.full_like(image, 127) if i == 2 else image,
                                        model=Model(), refresh_interval=30, retry_interval=2)
        self.assertEqual([r.source for r in result], ['detected', 'tracked', 'missing', 'missing', 'detected', 'tracked'])

    def test_owned_runtime_is_released_on_success_failure_and_cancellation(self):
        image, body = self.texture(23), Detection(60, 50, 160, 120, .8)
        for error in (None, RuntimeError('runtime error'), AircraftCancelled()):
            with self.subTest(error=error), patch('birdlock.core.aircraft_sequence.AircraftPartsModel') as factory:
                factory.return_value.detect.side_effect = error
                factory.return_value.detect.return_value = None
                if error is None:
                    analyze_aircraft_noses([body], lambda i: image)
                else:
                    with self.assertRaises(type(error)):
                        analyze_aircraft_noses([body], lambda i: image)
                factory.return_value.close.assert_called_once()
        model = AircraftPartsModel()
        model._session, model._meta = object(), {'test': True}
        model.close()
        self.assertIsNone(model._session)
        self.assertIsNone(model._meta)

    def test_no_subject_or_bad_ranges_do_not_create_runtime_or_read_photos(self):
        with patch('birdlock.core.aircraft_sequence.AircraftPartsModel') as factory:
            def unexpected(i):
                self.fail('Unexpected image decode')
            self.assertEqual(len(analyze_aircraft_noses([None]*3, unexpected)), 3)
            for clips in ([dict(start=1, count=2)], [dict(start=0, count=4)],
                          [dict(start=0, count=1)], [dict(start=0, count=2), dict(start=1, count=1)]):
                with self.assertRaises(ValueError):
                    analyze_aircraft_noses([None]*3, unexpected, clips=clips)
            factory.assert_not_called()

    def test_cancellation_after_decode_prevents_model_load(self):
        stop = False
        def read(i):
            nonlocal stop
            stop = True
            return self.texture(29)
        with patch('birdlock.core.aircraft_sequence.AircraftPartsModel') as factory:
            with self.assertRaises(AircraftCancelled):
                analyze_aircraft_noses([Detection(60, 50, 160, 120, .8)], read, cancelled=lambda: stop)
            factory.assert_not_called()



class AircraftThroughputTests(unittest.TestCase):
    def test_failed_retry_frames_do_not_decode_unneeded_proxies(self):
        reads=[]
        class Model:
            def detect(self,*a,**kw):return None
        bodies=[Detection(10,10,20,20,.9 if i==0 else .8) for i in range(12)]
        result=analyze_aircraft_noses(bodies,lambda i:(reads.append(i) or np.zeros((40,40,3),np.uint8)),model=Model())
        self.assertEqual(reads,[0,5,10]);self.assertTrue(all(r.nose is None for r in result))

    def test_color_region_tracking_matches_full_gray_even_at_image_edges(self):
        from birdlock.core.aircraft import NoseImageTracker
        rng=np.random.default_rng(111)
        image=rng.integers(0,256,(480,640,3),dtype=np.uint8)
        gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
        for origin in [(-30,-10),(5,20),(590,440),(200,100)]:
            for factor in [1,2,4]:
                np.testing.assert_array_equal(NoseImageTracker._patch(image,origin,factor),
                                              NoseImageTracker._patch(gray,origin,factor))


if __name__ == '__main__':
    unittest.main()
