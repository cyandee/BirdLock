import base64,importlib.util,json,tempfile,unittest,zipfile
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import rsa,padding
from cryptography.hazmat.primitives import serialization,hashes
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('update_packages',ROOT/'scripts/prepare_windows_update.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)

class UpdatePackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        self.keyfile=self.root/'private.pem';self.keyfile.write_bytes(self.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    def tearDown(self):self.tmp.cleanup()
    def archive(self,name,version,exe=b'program',extra=None):
        p=self.root/name
        with zipfile.ZipFile(p,'w') as z:
            for n,b in {'BirdLock.exe':exe,'_internal/VERSION':version.encode(),'_internal/model.bin':b'unchanged model','data/settings.json':b'private',**(extra or {})}.items():z.writestr('BirdLock/'+n,b)
        return p
    def test_signed_delta_reuses_model_and_excludes_user_data(self):
        old=self.archive('old.zip','1.5.0');new=self.archive('new.zip','1.5.1',b'new program');out=self.root/'out'
        m=mod.prepare(new,old,out,'https://github.com/cyandee/BirdLock/releases/download/v1.5.1',self.keyfile)
        envelope=json.loads((out/'windows.json').read_text());payload=base64.b64decode(envelope['payload'])
        self.key.public_key().verify(base64.b64decode(envelope['signature']),payload,padding.PKCS1v15(),hashes.SHA256())
        self.assertEqual(json.loads(payload)['version'],'1.5.1');self.assertFalse(any(n.startswith('data/') for n in m['files']))
        with zipfile.ZipFile(next(out.glob('*-files.zip'))) as z:self.assertEqual(set(z.namelist()),{'BirdLock.exe','_internal/VERSION'})
    def test_stable_feed_and_mirror(self):
        m=mod.prepare(self.archive('new.zip','1.5.1'),None,self.root/'out','https://github.com/releases/x',self.keyfile,'stable','https://assets.example.test')
        self.assertEqual((self.root/'out/windows.json').read_bytes(),(self.root/'out/windows-stable.json').read_bytes());self.assertIn('mirrors',m['full'])
    def test_rejects_path_traversal_and_case_collision(self):
        for n in ['../outside','data:stream','CON.txt','a\\b','a/../b','a\nfile']:
            with self.subTest(n=n):
                with self.assertRaises(ValueError):mod.name_ok(n)
        archive=self.archive('bad.zip','1.5.1',extra={'birdlock.EXE':b'duplicate'})
        with self.assertRaises(ValueError):mod.inventory(archive)
    def test_rejects_repeated_version_and_non_https(self):
        old=self.archive('old.zip','1.5.0');new=self.archive('new.zip','1.5.0')
        with self.assertRaises(ValueError):mod.prepare(new,old,self.root/'out','https://example.test',self.keyfile)
        with self.assertRaises(ValueError):mod.prepare(new,None,self.root/'out2','http://example.test',self.keyfile)

    def test_rejects_ambiguous_urls_and_file_directory_conflict(self):
        archive=self.archive('new.zip','1.5.1')
        for i,url in enumerate(['https://example.test/x?token=secret','https://user@example.test/x','https:///missing','https://example.test/x#fragment']):
            with self.assertRaises(ValueError):mod.prepare(archive,None,self.root/str(i),url,self.keyfile)
        bad=self.archive('conflict.zip','1.5.1',extra={'folder':b'file','FOLDER/child':b'child'})
        with self.assertRaises(ValueError):mod.inventory(bad)

    def test_beta_feed_retains_stable_asset_links(self):
        spec=importlib.util.spec_from_file_location('mac_updates',ROOT/'scripts/prepare_macos_update.py');mac=importlib.util.module_from_spec(spec);spec.loader.exec_module(mac)
        ns=mac.SPARKLE
        previous=self.root/'old.xml';current=self.root/'new.xml'
        previous.write_text(f'<rss xmlns:sparkle="{ns}"><channel><item><sparkle:version>1.4.9</sparkle:version><enclosure url="https://example.test/stable.zip"/></item><item><sparkle:version>1.5.0</sparkle:version><sparkle:channel>beta</sparkle:channel></item></channel></rss>')
        current.write_text(f'<rss xmlns:sparkle="{ns}"><channel><item><sparkle:version>1.5.1</sparkle:version><sparkle:channel>beta</sparkle:channel></item></channel></rss>')
        mac.retain_stable(current,previous)
        tree=mac.ET.parse(current);items=tree.findall('./channel/item')
        self.assertEqual([i.findtext(f'{{{ns}}}version') for i in items],['1.5.1','1.4.9'])
        self.assertEqual(items[1].find('enclosure').get('url'),'https://example.test/stable.zip')

    def test_beta_preserves_previously_signed_stable_feed(self):
        first=self.root/'stable';mod.prepare(self.archive('stable.zip','1.5.0'),None,first,'https://example.test/1.5.0',self.keyfile,'stable')
        beta=self.root/'beta';mod.prepare(self.archive('beta.zip','1.5.1'),None,beta,'https://example.test/1.5.1',self.keyfile,existing_stable=first/'windows-stable.json')
        self.assertEqual((first/'windows-stable.json').read_bytes(),(beta/'windows-stable.json').read_bytes())
        (first/'windows-stable.json').write_text('{}')
        with self.assertRaises((KeyError,ValueError)):mod.prepare(self.archive('next.zip','1.5.2'),None,self.root/'bad','https://example.test/1.5.2',self.keyfile,existing_stable=first/'windows-stable.json')
