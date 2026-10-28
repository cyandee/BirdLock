"""Create signed Windows update metadata and file-level deltas. Never publishes files."""
from pathlib import Path,PurePosixPath
import argparse,base64,hashlib,json,re,zipfile
from urllib.parse import urlsplit
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import padding

def name_ok(name):
    parts=name.split('/')
    if not name or any(ord(c)<32 for c in name) or len(name)>220 or any(c in name for c in '\\:\x00*?"<>|') or any(not p or p in ('.','..') or p.endswith(('.', ' ')) for p in parts): raise ValueError('Unsafe update path')
    if any(re.fullmatch(r'(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])',p.split('.')[0],re.I) for p in parts):raise ValueError('Reserved Windows path')
    if parts[0].lower()=='data':raise ValueError('User data cannot be updated')

def inventory(archive):
    entries={};folded=set()
    with zipfile.ZipFile(archive) as z:
        for e in z.infolist():
            if e.is_dir():continue
            n=e.filename.removeprefix('BirdLock/')
            if n.split('/')[0].lower()=='data':continue
            name_ok(n)
            if n.casefold() in folded or (e.external_attr>>16)&0xF000==0xA000:raise ValueError('Duplicate path or symlink')
            folded.add(n.casefold());entries[n]=z.read(e)
    if 'BirdLock.exe' not in entries or '_internal/VERSION' not in entries:raise ValueError('Incomplete Windows package')
    for n in entries:
        parents=PurePosixPath(n).parents
        if any(str(parent).casefold() in folded for parent in parents if str(parent)!='.'):
            raise ValueError('Conflicting file and directory paths')
    return entries

def describe(path):
    with path.open('rb') as f:digest=hashlib.file_digest(f,'sha256').hexdigest()
    return {'size':path.stat().st_size,'sha256':digest}

def write_zip(path,files):
    with zipfile.ZipFile(path,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for n,b in sorted(files.items()):
            e=zipfile.ZipInfo(n,date_time=(2020,1,1,0,0,0));e.compress_type=zipfile.ZIP_DEFLATED;e.external_attr=0o100644<<16;z.writestr(e,b)

def prepare(archive,previous,out,url_prefix,key_path,channel='beta',mirror=None,notes='',existing_stable=None):
    for prefix in [url_prefix]+([mirror] if mirror else []):
        u=urlsplit(prefix)
        if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment:raise ValueError('HTTPS directory URL without credentials, query or fragment required')
    if channel not in ('stable','beta'):raise ValueError('Unknown channel')
    files=inventory(archive);version=files['_internal/VERSION'].decode().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+',version):raise ValueError('Invalid package version')
    key=serialization.load_pem_private_key(key_path.read_bytes(),password=None)
    from cryptography.hazmat.primitives.asymmetric import rsa
    if not isinstance(key,rsa.RSAPrivateKey) or key.key_size<2048:raise ValueError('RSA key of at least 2048 bits required')
    # A production baseline must contain the matching updater public key and managed inventory.
    if '_internal/updates/config.json' in files:
        cfg=json.loads(files['_internal/updates/config.json'])['windows']
        pub=key.public_key().public_numbers()
        if int.from_bytes(base64.b64decode(cfg['rsa_modulus']),'big')!=pub.n or int.from_bytes(base64.b64decode(cfg['rsa_exponent']),'big')!=pub.e:
            raise ValueError('Signing key does not match the application public key')
        catalog=json.loads(files.get('_internal/updates/managed-files.json',b'[]'))
        if set(catalog)!=set(files) or '_internal/updater/BirdLockUpdater.exe' not in files:
            raise ValueError('Missing updater or inconsistent managed inventory')
    out.mkdir(parents=True,exist_ok=False)
    full=out/f'BirdLock-{version}-Windows-update.zip';write_zip(full,files)
    def package(p):
        result=dict(url=url_prefix.rstrip('/')+'/'+p.name,prefix='',**describe(p))
        if mirror:result['mirrors']=[mirror.rstrip('/')+'/'+p.name]
        return result
    manifest={'schema':1,'version':version,'channel':channel,'notes':notes,'full':package(full),'files':{n:{'size':len(b),'sha256':hashlib.sha256(b).hexdigest()} for n,b in files.items()}}
    if previous:
        old=inventory(previous);old_version=old['_internal/VERSION'].decode().strip()
        if tuple(map(int,old_version.split('.')))>=tuple(map(int,version.split('.'))):raise ValueError('Previous version must be older')
        changed={n:b for n,b in files.items() if old.get(n)!=b};delta=out/f'BirdLock-{old_version}-to-{version}-Windows-files.zip';write_zip(delta,changed)
        if delta.stat().st_size<full.stat().st_size:manifest['delta']=dict(package(delta),**{'from':old_version})
    payload=json.dumps(manifest,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
    signature=key.sign(payload,padding.PKCS1v15(),hashes.SHA256())
    (out/'windows.json').write_text(json.dumps({'payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(signature).decode()},indent=2)+'\n')
    stable=out/'windows-stable.json'
    if channel=='beta' and existing_stable:
        old_envelope=json.loads(existing_stable.read_bytes())
        old_payload=base64.b64decode(old_envelope['payload'],validate=True)
        key.public_key().verify(base64.b64decode(old_envelope['signature'],validate=True),old_payload,padding.PKCS1v15(),hashes.SHA256())
        if tuple(map(int,json.loads(old_payload)['version'].split('.')))>=tuple(map(int,version.split('.'))):raise ValueError('New release must advance beyond the existing feed')
        stable.write_bytes(existing_stable.read_bytes())
    else:
        # Bootstrap stable-only checks with an authenticated beta. The client filters it out.
        stable.write_bytes((out/'windows.json').read_bytes())
    (out/'traffic-report.json').write_text(json.dumps({'version':version,'full':full.stat().st_size,'delta':manifest.get('delta',{}).get('size'),'goal_under_30_MB':manifest.get('delta',{}).get('size',10**12)<30_000_000,'changed_files':len(changed) if previous else None},indent=2)+'\n')
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('--previous',type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--url-prefix',required=True);p.add_argument('--key-file',required=True,type=Path);p.add_argument('--mirror');p.add_argument('--channel',choices=['stable','beta'],default='beta');p.add_argument('--notes',default='');p.add_argument('--existing-stable-feed',type=Path);p.add_argument('--initial-release',action='store_true')
    a=p.parse_args()
    if a.channel=='beta' and not a.existing_stable_feed and not a.initial_release:p.error('Pass --existing-stable-feed, or --initial-release only when no feed has been published')
    prepare(a.archive,a.previous,a.output,a.url_prefix,a.key_file,a.channel,a.mirror,a.notes,a.existing_stable_feed)
