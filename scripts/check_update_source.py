"""Check an update source against the shared layout. Reads public files and keys only; never changes anything.

A source with base URL B serves, byte for byte:
  B/macos.xml, B/windows.json, B/windows-stable.json   copies of updates/ on main
  B/download/<tag>/<asset>                            copies of GitHub release assets
"""
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler,Request,build_opener
import argparse,base64,hashlib,json,re,sys,xml.etree.ElementTree as ET
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ed25519,padding,rsa

NS='http://www.andymatuschak.org/xml-namespaces/sparkle'
FEEDS=('macos.xml','windows.json','windows-stable.json')
UA='BirdLock-Updater/1 source-check'

def base_url(value):
    u=urlsplit(value)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment:raise ValueError('Source must be an HTTPS URL without credentials, query or fragment')
    return value if value.endswith('/') else value+'/'

def asset_url(base,canonical,prefix):
    if not canonical.startswith(prefix):raise ValueError('Not a release asset URL: '+canonical)
    return base+'download/'+canonical[len(prefix):]

class HttpsOnly(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if urlsplit(newurl).scheme!='https':raise ValueError('Redirect left HTTPS: '+newurl)
        return super().redirect_request(req,fp,code,msg,headers,newurl)
OPENER=build_opener(HttpsOnly)

def fetch(url,method='GET',first=None,last=None):
    headers={'User-Agent':UA}
    if first is not None:headers['Range']=f'bytes={first}-'+('' if last is None else str(last))
    try:
        with OPENER.open(Request(url,headers=headers,method=method),timeout=120) as r:
            return r.status,r.headers,(b'' if method=='HEAD' else r.read()),r.geturl()
    except HTTPError as e:return e.code,e.headers,b'',url
    except (OSError,ValueError) as e:return 0,{'X-Check-Error':f'{type(e).__name__}: {e}'},b'',url

def status_text(status,headers):
    return f'HTTP {status}' if status else headers.get('X-Check-Error','request failed')

def verify_windows(data,cfg):
    env=json.loads(data);payload=base64.b64decode(env['payload'],validate=True)
    key=rsa.RSAPublicNumbers(int.from_bytes(base64.b64decode(cfg['rsa_exponent']),'big'),int.from_bytes(base64.b64decode(cfg['rsa_modulus']),'big')).public_key()
    key.verify(base64.b64decode(env['signature'],validate=True),payload,padding.PKCS1v15(),hashes.SHA256())
    return json.loads(payload)

def verify_macos(data,cfg):
    key=ed25519.Ed25519PublicKey.from_public_bytes(base64.b64decode(cfg['ed25519_public_key']))
    content,suffix=data.rsplit(b'<!-- sparkle-signatures:\n',1)
    match=re.fullmatch(rb'edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*',suffix)
    if not match or int(match[2])!=len(content):raise ValueError('Malformed signed appcast')
    key.verify(base64.b64decode(match[1],validate=True),content)
    return ET.fromstring(content),key

def assets(feeds,cfg):
    """Every downloadable file the signed feeds reference, with the check that proves its bytes."""
    found={}
    for name in ('windows.json','windows-stable.json'):
        manifest=verify_windows(feeds[name],cfg['windows'])
        for kind in ('full','delta'):
            spec=manifest.get(kind)
            if spec:found[spec['url']]=(spec['size'],lambda b,s=spec['sha256']:hashlib.sha256(b).hexdigest()==s)
    root,key=verify_macos(feeds['macos.xml'],cfg['macos'])
    def signed(signature):
        def check(b):
            try:key.verify(base64.b64decode(signature,validate=True),b);return True
            except Exception:return False
        return check
    for item in root.iter('item'):
        for e in item.iter('enclosure'):found[e.get('url')]=(int(e.get('length')),signed(e.get('{'+NS+'}edSignature','')))
        for e in item.iter('{'+NS+'}deltas'):
            for d in e.iter('enclosure'):found[d.get('url')]=(int(d.get('length')),signed(d.get('{'+NS+'}edSignature','')))
        note=item.find('{'+NS+'}releaseNotesLink')
        if note is not None and note.get('{'+NS+'}edSignature'):found[note.text.strip()]=(int(note.get('{'+NS+'}length','0')),signed(note.get('{'+NS+'}edSignature')))
    return found

def check(base,cfg,compare=True,full_limit=16*1024*1024):
    base=base_url(base);prefix=cfg['release_download_prefix'];results=[]
    def record(ok,name,detail=''):
        results.append({'ok':bool(ok),'check':name,'detail':detail});print(('PASS ' if ok else 'FAIL ')+name+(' · '+detail if detail else ''),flush=True)
    reference={'macos.xml':cfg['macos']['feed_url'],'windows.json':cfg['windows']['feed_url'],'windows-stable.json':cfg['windows'].get('stable_feed_url') or cfg['windows']['feed_url']}
    feeds={}
    for name in FEEDS:
        status,headers,body,final=fetch(base+name)
        ok=status==200 and final.startswith('https://') and not headers.get('Content-Encoding')
        record(ok,'feed '+name,status_text(status,headers)+f', {len(body)} B, sha256 {hashlib.sha256(body).hexdigest()[:16]}')
        if not ok:continue
        try:(verify_macos if name=='macos.xml' else verify_windows)(body,cfg['macos' if name=='macos.xml' else 'windows']);record(True,'signature '+name)
        except Exception as e:record(False,'signature '+name,str(e));continue
        feeds[name]=body
        if compare:
            upstream=fetch(reference[name])[2];record(upstream==body,'identical to GitHub '+name,'' if upstream==body else 'mirror may still be within its cache TTL')
    if len(feeds)!=len(FEEDS):return results
    for canonical,(size,valid) in assets(feeds,cfg).items():
        try:url=asset_url(base,canonical,prefix)
        except ValueError as e:record(False,'asset route',str(e));continue
        label=canonical[len(prefix):]
        status,headers,_,final=fetch(url,'HEAD')
        record(status==200 and final.startswith('https://') and headers.get('Content-Length')==str(size),'HEAD '+label,status_text(status,headers)+f', Content-Length {headers.get("Content-Length")}, expected {size}')
        first=max(0,size-65536);status,headers,body,_=fetch(url,first=first)
        expected=f'bytes {first}-{size-1}/{size}'
        record(status==206 and headers.get('Content-Range')==expected and len(body)==size-first and not headers.get('Content-Encoding'),'Range '+label,status_text(status,headers)+f', {headers.get("Content-Range")}')
        if size<=full_limit:
            status,headers,body,_=fetch(url)
            record(status==200 and len(body)==size and valid(body),'content '+label,status_text(status,headers)+f', {len(body)} B, signature or SHA256 checked')
    for missing in ('download/v0.0.0/BirdLock-0.0.0-source-check.zip','source-check-missing.json'):
        status,headers,body,_=fetch(base+missing);record(status==404,'missing '+missing,status_text(status,headers))
    return results

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('base');p.add_argument('--config',type=Path,default=Path(__file__).resolve().parents[1]/'SharedResources/Updates/config.json')
    p.add_argument('--no-compare',action='store_true',help='skip the byte comparison with the GitHub feeds')
    p.add_argument('--full-limit',type=int,default=16*1024*1024,help='download and verify assets up to this size in bytes')
    p.add_argument('--output',type=Path,help='write a public JSON receipt')
    a=p.parse_args();results=check(a.base,json.loads(a.config.read_bytes()),not a.no_compare,a.full_limit)
    if a.output:a.output.write_text(json.dumps({'base':base_url(a.base),'results':results},ensure_ascii=False,indent=2)+'\n')
    failed=[r for r in results if not r['ok']];print(f'{len(results)-len(failed)}/{len(results)} checks passed');sys.exit(1 if failed else 0)
