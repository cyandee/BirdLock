"""Reopening a large cached burst should enumerate once, without per-photo mkdir."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from birdlock.core.analysis import ProxyCache, SequenceAnalysis, FrameAnalysis
from birdlock.core.frames import SourceFrame
from birdlock.core.models import PoseSchema


class CachedBurstTests(unittest.TestCase):
    def fixture(self,root,count=80):
        cache=ProxyCache(Path(root));fp='test-cache-scan'
        frames=[SourceFrame(i,f'photo-{i}.jpg',64,64) for i in range(count)]
        a=SequenceAnalysis(fp,frames,30,2560,[FrameAnalysis(i) for i in range(count)],PoseSchema([]))
        a.manualEye={2:(10.,12.)};a.excluded={3};cache.save_analysis(a)
        directory=cache.directory(fp)
        for i in range(count):(directory/f'p{i:05d}.jpg').touch()
        return cache,a

    def test_single_directory_read_preserves_all_cached_edits(self):
        with tempfile.TemporaryDirectory() as td:
            cache,a=self.fixture(td)
            with patch.object(cache,'directory',side_effect=AssertionError('read attempted mkdir')):
                loaded=cache.load_analysis(a.fingerprint)
            self.assertEqual(loaded.count,a.count)
            self.assertEqual(loaded.manualEye,a.manualEye);self.assertEqual(loaded.excluded,a.excluded)

    def test_missing_proxy_or_directory_instead_of_photo_rejects_cache(self):
        with tempfile.TemporaryDirectory() as td:
            cache,a=self.fixture(td)
            path=cache.root/a.fingerprint/'p00010.jpg';path.unlink()
            self.assertIsNone(cache.load_analysis(a.fingerprint))
            path.mkdir();self.assertIsNone(cache.load_analysis(a.fingerprint))

    def test_missing_proxy_read_does_not_create_a_cache_directory(self):
        with tempfile.TemporaryDirectory() as td:
            cache=ProxyCache(Path(td)/'not-created')
            self.assertIsNone(cache.load_proxy('missing',0))
            self.assertFalse(cache.root.exists())
