"""A runtime provider fallback must not leave the bird-head UI claiming GPU use."""
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from birdlock.core.models import BirdModels, YOLOModel


class ModelDiagnosticsTests(unittest.TestCase):
    def model(self, fail=False):
        model = YOLOModel.__new__(YOLOModel)
        model._lock = threading.Lock()
        model._timing = dict(calls=0, preprocess=0.0, queue=0.0, inference=0.0)
        model.providers = ['DmlExecutionProvider', 'CPUExecutionProvider']
        model.input_size = 32
        model.input_name, model.output_name = 'images', 'output'
        model.num_keypoints, model.num_classes, model.class_names = 0, 1, ['bird']

        def run(*args):
            if fail:
                raise RuntimeError('inference failed')
            return [np.array([[[16], [16], [8], [8], [.9]]], dtype=np.float32)]

        model.session = SimpleNamespace(run=run, get_providers=lambda: ['CPUExecutionProvider'])
        return model

    def test_runtime_fallback_updates_provider_and_counts_one_inference(self):
        model = self.model()
        before = model.timing_snapshot()
        result = model.detect(np.zeros((32, 32, 3), np.uint8))
        self.assertEqual(len(result), 1)
        self.assertEqual(model.providers, ['CPUExecutionProvider'])
        after = model.timing_snapshot()
        self.assertEqual(before['calls'], 0)
        self.assertEqual(after['calls'], 1)
        self.assertTrue(all(after[key] >= 0 for key in ('preprocess', 'queue', 'inference')))
        after['calls'] = 99
        self.assertEqual(model.timing_snapshot()['calls'], 1)

    def test_failed_inference_is_timed_and_releases_lock(self):
        model = self.model(fail=True)
        with self.assertRaisesRegex(RuntimeError, 'inference failed'):
            model.detect(np.zeros((32, 32, 3), np.uint8))
        self.assertEqual(model.timing_snapshot()['calls'], 1)
        self.assertEqual(model.providers, ['CPUExecutionProvider'])

    def test_bird_head_device_is_independent_from_detector(self):
        models = BirdModels.__new__(BirdModels)
        models.device = 'auto'
        models.detector = SimpleNamespace(providers=['DmlExecutionProvider'])
        models.pose = SimpleNamespace(providers=['CPUExecutionProvider'])
        with patch('birdlock.core.models.gpu.describe_device', side_effect=lambda ps, _: ps[0]):
            self.assertIn('鸟头：CPUExecutionProvider', models.device_description)
            self.assertEqual(models.device_for_stage('识别鸟'), 'DmlExecutionProvider')
            self.assertEqual(models.device_for_stage('定位鸟头/鸟眼'), 'CPUExecutionProvider')
            self.assertEqual(models.device_for_stage('亚像素配准'), 'CPU')


if __name__ == '__main__':
    unittest.main()
