"""Verify locally prepared public update files; never uploads or reads private keys."""
from pathlib import Path
from urllib.parse import urlsplit,unquote
import argparse,base64,hashlib,json,re,zipfile,xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric import rsa,padding,ed25519
from cryptography.hazmat.primitives import hashes
NS='http://www.andymatuschak.org/xml-namespaces/sparkle'

def asset(directory,url):
    u=urlsplit(url);name=unquote(u.path.rsplit('/',1)[-1])
    if u.scheme!='https' or u.username or u.password or not name or Path(name).name!=name or '\\' in name:raise ValueError('Unsafe public asset URL')
    p=directory/name
    if not p.is_file():raise ValueError('Missing asset: '+name)
    return p

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def windows(feed,directory,config,version):
    env=json.loads(feed.read_bytes());payload=base64.b64decode(env['payload'],validate=True)
    key=rsa.RSAPublicNumbers(int.from_bytes(base64.b64decode(config['rsa_exponent']),'big'),int.from_bytes(base64.b64decode(config['rsa_modulus']),'big')).public_key()
    key.verify(base64.b64decode(env['signature'],validate=True),payload,padding.PKCS1v15(),hashes.SHA256())
    manifest=json.loads(payload)
    if manifest['schema']!=1 or manifest['version']!=version:raise ValueError('Windows release version mismatch')
    files=[]
    for kind in ('full','delta'):
        spec=manifest.get(kind)
        if not spec:continue
        archive=asset(directory,spec['url'])
        if archive.stat().st_size!=spec['size'] or digest(archive)!=spec['sha256']:raise ValueError('Package hash mismatch')
        with zipfile.ZipFile(archive) as z:
            actual={e.filename for e in z.infolist() if not e.is_dir()}
            expected=set(manifest['files'])
            if (kind=='full' and actual!=expected) or not actual<=expected:raise ValueError('Update archive inventory mismatch')
            for name in actual:
                specfile=manifest['files'][name]
                with z.open(name) as stream:
                    h=hashlib.sha256();size=0
                    while block:=stream.read(1024*1024):h.update(block);size+=len(block)
                if size!=specfile['size'] or h.hexdigest()!=specfile['sha256']:raise ValueError('File hash mismatch: '+name)
            if kind=='full' and z.read('_internal/VERSION').decode().strip()!=version:raise ValueError('Embedded version mismatch')
        files.append({'name':archive.name,'bytes':archive.stat().st_size,'sha256':digest(archive)})
    return files

def macos(feed,directory,config,version):
    key=ed25519.Ed25519PublicKey.from_public_bytes(base64.b64decode(config['ed25519_public_key']))
    prefix,suffix=feed.read_bytes().rsplit(b'<!-- sparkle-signatures:\n',1)
    match=re.fullmatch(rb'edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*',suffix)
    if not match or int(match[2])!=len(prefix):raise ValueError('Malformed signed appcast')
    key.verify(base64.b64decode(match[1],validate=True),prefix)
    items=ET.parse(feed).findall('./channel/item');current=[i for i in items if i.findtext('{'+NS+'}version')==version]
    if len(current)!=1:raise ValueError('Missing or repeated Mac version')
    result=[]
    for enclosure in current[0].iter('enclosure'):
        p=asset(directory,enclosure.get('url'));data=p.read_bytes()
        if len(data)!=int(enclosure.get('length')):raise ValueError('Mac archive size mismatch')
        key.verify(base64.b64decode(enclosure.get('{'+NS+'}edSignature'),validate=True),data)
        result.append({'name':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(data).hexdigest()})
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--version',required=True);p.add_argument('--config',type=Path,default=Path(__file__).resolve().parents[1]/'SharedResources/Updates/config.json');p.add_argument('--mac-feed',type=Path);p.add_argument('--windows-feed',type=Path);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();cfg=json.loads(a.config.read_bytes());report={'version':a.version}
    if a.mac_feed:report['macos']=macos(a.mac_feed,a.mac_feed.parent,cfg['macos'],a.version)
    if a.windows_feed:report['windows']=windows(a.windows_feed,a.windows_feed.parent,cfg['windows'],a.version)
    if len(report)==1:p.error('At least one signed feed is required')
    a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print('Signed feeds, archives and file inventories verified. No remote changes.')
