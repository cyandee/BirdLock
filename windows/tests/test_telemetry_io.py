import json
import math
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from birdlock.core.telemetry_io import TelemetryCancelled, helper_path, read_telemetry, validate_report

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'tools/telemetry/tests/fixtures/known-rates.gcsv'


class TelemetryIOTests(unittest.TestCase):
    def test_rejects_wrong_units_nonfinite_time_and_axes(self):
        report = dict(schema=1, gyroUnit='rad/s', timestampUnit='s', orientation='XYZ',
                      imuFrame='gyroflow-x-up-y-left-z-back', cameraFrame='opencv-x-right-y-down-z-forward',
                      imuToCamera=[[0, -1, 0], [-1, 0, 0], [0, 0, -1]], samples=[])
        self.assertIs(validate_report(report), report)
        for change in [dict(gyroUnit='deg/s'), dict(imuToCamera=[[1, 0, 0], [0, 1, 0], [0, 0, 1]]),
                       dict(samples=[dict(t=math.nan, gyro=[0, 0, 0])]),
                       dict(samples=[dict(t=0, gyro=[0, 0, 0]), dict(t=0, gyro=[1, 2, 3])])]:
            with self.assertRaises(ValueError):
                validate_report({**report, **change})

    def test_cancelled_before_process_start(self):
        with patch('birdlock.core.telemetry_io.helper_path', return_value='/unused/helper'):
            with self.assertRaises(TelemetryCancelled):
                read_telemetry(FIXTURE, cancelled=lambda: True)

    @unittest.skipUnless(helper_path(), 'build the telemetry helper first')
    def test_real_helper_preserves_units_and_does_not_modify_source(self):
        original = FIXTURE.read_bytes()
        report = read_telemetry(FIXTURE)
        self.assertEqual(FIXTURE.read_bytes(), original)
        self.assertEqual(report['parser'], 'GyroflowGcsv')
        self.assertEqual(len(report['samples']), 3)
        self.assertAlmostEqual(report['samples'][0]['t'], 0.)
        self.assertAlmostEqual(report['samples'][1]['t'], .01)
        self.assertEqual(report['samples'][0]['gyro'], [1., -2., 3.])
        self.assertAlmostEqual(report['samples'][0]['accel'][1], 9.80665)
        self.assertFalse(report['timestampsAccurate'])

    @unittest.skipUnless(helper_path(), 'build the telemetry helper first')
    def test_project_embedded_and_relative_reference(self):
        with tempfile.TemporaryDirectory(prefix='birdlock-telemetry-test-') as temporary:
            folder = Path(temporary)
            source = folder / 'motion.gcsv'
            source.write_bytes(FIXTURE.read_bytes())
            project = folder / 'motion.gyroflow'
            project.write_text(json.dumps({'gyro_source': {'filepath': 'motion.gcsv', 'imu_orientation': 'YxZ'}}))
            report = read_telemetry(project)
            self.assertEqual(report['samples'][0]['gyro'], [-2., -1., 3.])
            project.write_text(json.dumps({'gyro_source': {'imu_orientation': 'YxZ', 'raw_imu': [
                {'timestamp_ms': 1250, 'gyro': [180, 90, -45], 'accl': None, 'magn': None}]}}))
            report = read_telemetry(project)
            self.assertEqual(report['samples'][0]['t'], 1.25)
            self.assertAlmostEqual(report['samples'][0]['gyro'][0], math.pi / 2)
            self.assertAlmostEqual(report['samples'][0]['gyro'][1], -math.pi)

    @unittest.skipUnless(helper_path(), 'build the telemetry helper first')
    def test_controlled_sony_rtmd_packet_clocks_radians_and_factory_bias(self):
        report = read_telemetry(FIXTURE.with_name('controlled-sony-units.mp4'))
        self.assertEqual(report['cameraModel'], 'ControlledTelemetryFixture')
        self.assertEqual(report['metadataFrameCount'], 2)
        self.assertEqual(report['gyroscopeFrameCount'], 2)
        self.assertTrue(report['sonyPacketTimed'])
        self.assertEqual([s['t'] for s in report['samples']], [-.001, 0., .009, .01])
        for actual, expected in zip(report['samples'][0]['gyro'], [18., 9., -27.]):
            self.assertAlmostEqual(actual, expected)
        self.assertEqual(report['warnings'], [])

    @unittest.skipUnless(helper_path(), 'build the telemetry helper first')
    def test_malformed_gcsv_is_rejected_instead_of_becoming_zero(self):
        with tempfile.TemporaryDirectory(prefix='birdlock-telemetry-test-') as temporary:
            source = Path(temporary) / 'invalid.gcsv'
            source.write_text(FIXTURE.read_text().replace('100,-200', 'bad,-200'))
            with self.assertRaisesRegex(ValueError, 'not a number'):
                read_telemetry(source)


if __name__ == '__main__':
    unittest.main()
