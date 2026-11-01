import json
from pathlib import Path
import shutil
import tempfile
import unittest

from scripts.verify_bundle import verify_lens_profiles


SOURCE = Path(__file__).resolve().parents[2] / 'SharedResources' / 'LensProfiles'


class LensBundleTests(unittest.TestCase):
    def stage(self, root):
        return Path(shutil.copytree(SOURCE, Path(root) / 'lens_profiles'))

    def test_both_distribution_layouts_preserve_profiles_manifest_and_licenses(self):
        verify_lens_profiles(SOURCE)
        expected = {p.relative_to(SOURCE): p.read_bytes() for p in SOURCE.rglob('*') if p.is_file()}
        with tempfile.TemporaryDirectory() as folder:
            for suffix in ('BirdLock.app/Contents/Resources/LensProfiles', 'BirdLock/_internal/lens_profiles'):
                packaged = Path(folder) / suffix
                shutil.copytree(SOURCE, packaged)
                verify_lens_profiles(packaged)
                actual = {p.relative_to(packaged): p.read_bytes() for p in packaged.rglob('*') if p.is_file()}
                self.assertEqual(actual, expected)

    def test_missing_or_changed_profile_fails(self):
        for damage in ('missing', 'changed'):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as folder:
                root = self.stage(folder)
                manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
                profile = root / manifest['profiles'][0]['file']
                if damage == 'missing': profile.unlink()
                else: profile.write_bytes(profile.read_bytes() + b' ')
                with self.assertRaisesRegex(ValueError, '校验失败'):
                    verify_lens_profiles(root)

    def test_truncated_cc0_and_missing_source_notice_fail(self):
        for damage in ('license', 'notice'):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as folder:
                root = self.stage(folder)
                if damage == 'license': (root / 'CC0-1.0.txt').write_text('CC0', encoding='utf-8')
                else: (root / 'README.md').unlink()
                with self.assertRaisesRegex(ValueError, '许可文件不完整|来源说明'):
                    verify_lens_profiles(root)

    def test_duplicate_unsafe_names_and_unpinned_sources_fail(self):
        for damage in ('duplicate', 'path', 'source'):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as folder:
                root = self.stage(folder)
                file = root / 'manifest.json'
                manifest = json.loads(file.read_text(encoding='utf-8'))
                if damage == 'duplicate': manifest['profiles'].append(manifest['profiles'][0])
                elif damage == 'path': manifest['profiles'][0]['file'] = '..\\outside.json'
                else: manifest['profiles'][0]['sourceURL'] = 'https://github.com/gyroflow/lens_profiles/blob/main/profile.json'
                file.write_text(json.dumps(manifest), encoding='utf-8')
                with self.assertRaisesRegex(ValueError, '文件名或标识|固定官方来源'):
                    verify_lens_profiles(root)
