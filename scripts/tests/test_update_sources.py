import json,unittest
from pathlib import Path
from scripts.stage_updater import source_settings
from scripts.check_update_source import asset_url,base_url

ROOT=Path(__file__).resolve().parents[2]

class UpdateSourceTests(unittest.TestCase):
    def test_shipped_sources_put_github_first_then_mirror(self):
        cfg=json.loads((ROOT/'SharedResources/Updates/config.json').read_text(encoding='utf-8'))
        settings=source_settings(cfg)
        self.assertEqual(settings['BirdLockUpdateSources'][0],{'id':'github','name':'GitHub'})
        self.assertEqual(settings['BirdLockUpdateSources'][1]['url'],'https://3rd.0x01.page/birdlock/update-api/')
        self.assertEqual(settings['BirdLockReleaseDownloadPrefix'],'https://github.com/cyandee/BirdLock/releases/download/')
        for name in ('macos.xml','windows.json'):
            self.assertTrue(cfg['macos' if name=='macos.xml' else 'windows']['feed_url'].endswith('/updates/'+name),'mirrors relay the repository feeds by name')

    def test_invalid_sources_are_rejected_before_signing(self):
        for url in ('http://m.test/','https://u:p@m.test/','https://m.test/?a','https://m.test/#a','https://m.test/no-slash'):
            with self.assertRaises(ValueError,msg=url):source_settings({'sources':[{'url':url}]})
        with self.assertRaises(ValueError):source_settings({'sources':[{'id':'github'},{'id':'github'}]})
        self.assertEqual(source_settings({}),{'BirdLockUpdateSources':[{'id':'github','name':'GitHub'}]})

    def test_checker_maps_release_assets_with_their_tag(self):
        prefix='https://github.com/cyandee/BirdLock/releases/download/'
        base=base_url('https://3rd.0x01.page/birdlock/update-api')
        self.assertEqual(asset_url(base,prefix+'v1.5.0-beta.1/BirdLock-1.5.0-Windows-update.zip',prefix),
                         'https://3rd.0x01.page/birdlock/update-api/download/v1.5.0-beta.1/BirdLock-1.5.0-Windows-update.zip')
        with self.assertRaises(ValueError):asset_url(base,'https://elsewhere.test/a.zip',prefix)
        with self.assertRaises(ValueError):base_url('http://3rd.0x01.page/birdlock/update-api/')

    def test_checker_records_network_errors_instead_of_crashing(self):
        from unittest.mock import patch
        from urllib.error import URLError
        from scripts import check_update_source as c
        for error in (URLError('dns'),TimeoutError('slow'),ValueError('Redirect left HTTPS: http://x/')):
            with patch.object(c.OPENER,'open',side_effect=error):
                status,headers,body,_=c.fetch('https://m.test/macos.xml')
            self.assertEqual((status,body),(0,b''));self.assertIn(type(error).__name__,c.status_text(status,headers))
        with patch.object(c.OPENER,'open',side_effect=URLError('dns')):
            results=c.check('https://m.test/',json.loads((ROOT/'SharedResources/Updates/config.json').read_text(encoding='utf-8')))
        self.assertEqual(len(results),3);self.assertFalse(any(r['ok'] for r in results))

if __name__=='__main__':unittest.main()
