import json
import os
from pathlib import Path
from unittest.mock import patch
import shutil
import tempfile
import unittest

import numpy as np

from birdlock.core.camera_metadata import CameraMetadata, metadata_for_video, parse_sony_xml
from birdlock.core.lens_catalog import directory, entries, import_xml, match, detect
from birdlock.core.lens_profile import LensProfile


def sony_xml(camera='ILCE-1M2', lens='FE 600mm F4 GM OSS', focal=''):
    # Relevant fields of the supplied C0320M01.XML, with identifiers and timestamps omitted.
    return f'''<?xml version="1.0" encoding="UTF-8"?>
    <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
      <VideoFormat><VideoFrame captureFps="119.88p" formatFps="119.88p"/>
      <VideoLayout pixel="3840" numOfVerticalLine="2160" aspectRatio="16:9"/></VideoFormat>
      <Device manufacturer="Sony" modelName="{camera}" serialNo="ignored"/>
      <Lens modelName="{lens}"/>
      <AcquisitionRecord><ChangeTable name="Gyroscope"><Event frameCount="0" status="none"/></ChangeTable>
      <ChangeTable name="DistortionCorrection"><Event frameCount="0" status="none"/></ChangeTable>
      {focal}</AcquisitionRecord>
    </NonRealTimeMeta>'''.encode()


class LensCatalogTests(unittest.TestCase):
    def test_video_detection_uses_embedded_telemetry_and_does_not_guess_eis(self):
        report=dict(cameraBrand='GoPro',cameraModel='HERO11 Black',video=dict(fps=119.88),rawMetadataFrames=[dict(Default={'0x56464f56':'W','0x45495341':'N'})])
        with patch('birdlock.core.telemetry_io.read_telemetry',return_value=report) as reader:
            result=detect('no-sidecar.mp4',3840,2160,119.88)
            self.assertEqual(result.selected.id,'gopro-hero11-wide-4k120')
            reader.assert_called_once_with('no-sidecar.mp4',probe=True,timeout=30)
        report['rawMetadataFrames'][0]['Default'].pop('0x45495341')
        with patch('birdlock.core.telemetry_io.read_telemetry',return_value=report):
            result=detect('no-sidecar.mp4',3840,2160,119.88)
            self.assertEqual(result.metadata.cameraModel,'HERO11 Black');self.assertIsNone(result.selected)
        report=dict(cameraBrand='DJI',cameraModel='DJI Mini 3 Pro',video={},rawMetadataFrames=[])
        with patch('birdlock.core.telemetry_io.read_telemetry',return_value=report):
            self.assertEqual(detect('no-sidecar.mp4',1920,1080,29.97).selected.id,'dji-mini3pro-1080p30')

    def test_eight_verified_real_profiles_load_and_render_maps(self):
        all_entries = entries()
        self.assertEqual(len(all_entries), 383)
        for entry in all_entries:
            self.assertIn('/886fc616c9c2c788856f54c21d451b9cb7fc4f44/', entry.sourceURL)
            lens = LensProfile.load(entry.url)
            w, h = 1024, round(1024*entry.height/entry.width)
            x, y = lens.maps(w,h)
            self.assertTrue(np.isfinite(x).all() and np.isfinite(y).all())
        self.assertIn('CC0 1.0 Universal', (directory()/'CC0-1.0.txt').read_text(encoding="utf-8"))

    def test_sony_xml_reads_supplied_camera_without_faking_calibration(self):
        actual = os.environ.get('BIRDLOCK_TEST_SONY_XML')
        camera = parse_sony_xml(Path(actual).read_bytes() if actual else sony_xml())
        self.assertEqual((camera.cameraBrand,camera.cameraModel,camera.lensModel),('Sony','ILCE-1M2','FE 600mm F4 GM OSS'))
        self.assertEqual((camera.width,camera.height,camera.fps),(3840,2160,119.88))
        self.assertIsNone(camera.focalLength)
        self.assertFalse(camera.variableFocalLength)
        self.assertNotIn('serialNo',camera.to_dict())
        selected = match(camera,3840,2160,119.88)
        self.assertIsNone(selected.selected_url)
        self.assertEqual(selected.candidates,[])

    def test_exact_prime_and_zoom_matching_need_lens_focal_mode_and_dimensions(self):
        prime = CameraMetadata(cameraBrand='Sony',cameraModel='ILME-FX3',lensModel='FE 24mm F1.4 GM')
        self.assertEqual(match(prime,3840,2160,25).selected.id,'sony-fx3-fe24gm-4k25')
        self.assertIsNone(match(CameraMetadata(cameraBrand='Canon',cameraModel='FX3',lensModel=prime.lensModel),3840,2160,25).selected)
        self.assertIsNone(match(CameraMetadata(cameraModel='FX3'),3840,2160,25).selected)
        self.assertIsNone(match(prime,1920,1080,25).selected)
        self.assertIsNone(match(prime,3840,2160,59.94).selected)
        self.assertIsNone(match(prime,3840,2160,0).selected)
        self.assertIsNone(match(prime,3840,0,25).selected)
        prime.stabilizationMode='Active'
        self.assertIsNone(match(prime,3840,2160,25).selected)
        prime.stabilizationMode=''
        prime.cameraSetting='APS-C'
        self.assertIsNone(match(prime,3840,2160,25).selected)
        zoom = CameraMetadata(cameraModel='ILCE-7M4',lensModel='Sigma 28-70mm 2.8')
        self.assertEqual(len(match(zoom,3840,2160,25).candidates),1)
        self.assertIsNone(match(zoom,3840,2160,25).selected)
        zoom.focalLength=28
        self.assertEqual(match(zoom,3840,2160,25).selected.id,'sony-a7iv-sigma28-70-28-4k25')
        zoom.variableFocalLength=True
        self.assertIsNone(match(zoom,3840,2160,25).selected)

    def test_gopro_requires_known_eis_mode_and_fixed_camera_matches(self):
        camera = CameraMetadata(cameraModel='HERO11 Black',lensModel='Wide')
        self.assertIsNone(match(camera,3840,2160,119.88).selected)
        camera.stabilizationMode='off'
        self.assertEqual(match(camera,3840,2160,119.88).selected.id,'gopro-hero11-wide-4k120')
        mini=CameraMetadata(cameraBrand='DJI',cameraModel='DJI Mini 3 Pro')
        self.assertEqual(match(mini,1920,1080,29.97).selected.id,'dji-mini3pro-1080p30')

    def test_sidecar_case_embedded_xml_and_xml_reference_import(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);video=folder/'C0320.MP4';video.write_bytes(b'not a decoded video')
            sidecar=folder/'c0320m01.xml';sidecar.write_bytes(sony_xml())
            self.assertEqual(metadata_for_video(video).cameraModel,'ILCE-1M2')
            self.assertEqual(import_xml(sidecar).metadata.lensModel,'FE 600mm F4 GM OSS')
            with self.assertRaisesRegex(ValueError,'XML'):
                LensProfile.load(sidecar)
            sidecar.unlink();video.write_bytes(b'\0'*50+sony_xml()+b'\0'*50)
            self.assertEqual(metadata_for_video(video).source,'embedded-sony-xml')
            # A real XML reference with an exact static catalogue match resolves to a valid profile.
            profile_xml=sony_xml('ILME-FX3','FE 24mm F1.4 GM').replace(b'119.88p',b'25p')
            sidecar.write_bytes(profile_xml)
            self.assertEqual(LensProfile.load(sidecar).name,LensProfile.load(match(CameraMetadata(cameraModel='FX3',lensModel='FE 24mm F1.4 GM'),3840,2160,25).selected_url).name)

    def test_rejects_dtd_mismatch_and_corrupt_catalogue(self):
        with self.assertRaises(ValueError):parse_sony_xml(b'<!DOCTYPE x [<!ENTITY y SYSTEM "file:///etc/passwd">]><NonRealTimeMeta/>')
        with self.assertRaises(ValueError):parse_sony_xml(b'<not-sony/>')
        metadata=parse_sony_xml(sony_xml())
        self.assertIn('尺寸不同',match(metadata,1920,1080,119.88).message)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            shutil.copytree(directory(),root,dirs_exist_ok=True)
            first=json.loads((root/'manifest.json').read_text(encoding="utf-8"))['profiles'][0]['file']
            (root/first).write_text('{}')
            with self.assertRaisesRegex(ValueError,'校验失败'):entries(root)
