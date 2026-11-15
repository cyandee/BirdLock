"""Embed Sparkle without changing its symlinks; insert public update settings before signing."""
from pathlib import Path
import argparse,base64,json,plistlib,subprocess
from urllib.parse import urlsplit

SOURCE_KEYS=('BirdLockUpdateSources','BirdLockReleaseDownloadPrefix')

def https_directory(value,label):
    u=urlsplit(value)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or not u.path.endswith('/'):
        raise ValueError(label+' must be an HTTPS directory URL without credentials, query or fragment')
    return value

def source_settings(cfg):
    """Shipped source order. Other sources relay <base>/macos.xml and <base>/download/<tag>/<asset> byte for byte."""
    sources=[]
    for s in cfg.get('sources') or [{'id':'github'}]:
        if s.get('id')=='github':sources.append({'id':'github','name':s.get('name') or 'GitHub'})
        else:
            url=https_directory(s['url'],'Update source');sources.append({'name':s.get('name') or urlsplit(url).hostname,'url':url})
    if len({json.dumps(s,sort_keys=True) for s in sources})!=len(sources):raise ValueError('Duplicate update source')
    settings={'BirdLockUpdateSources':sources}
    if cfg.get('release_download_prefix'):settings['BirdLockReleaseDownloadPrefix']=https_directory(cfg['release_download_prefix'],'Release download prefix')
    return settings

def stage(app: Path, root: Path, config_path: Path):
    cfg=json.loads(config_path.read_text());mac=cfg['macos']
    framework=root/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    if not framework.is_dir(): raise ValueError('Sparkle framework is missing; resolve the pinned Swift package first')
    dest=app/'Contents/Frameworks/Sparkle.framework';dest.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['/usr/bin/ditto',str(framework),str(dest)],check=True)
    p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
    if cfg.get('enabled',False):
        if len(base64.b64decode(mac['ed25519_public_key'],validate=True))!=32: raise ValueError('Invalid Sparkle public key')
        u=urlsplit(mac['feed_url'])
        if u.scheme!='https' or not u.hostname or u.username or u.password or u.fragment: raise ValueError('Appcast must use HTTPS without credentials')
        info.update(SUFeedURL=mac['feed_url'],SUPublicEDKey=mac['ed25519_public_key'],SURequireSignedFeed=True,SUVerifyUpdateBeforeExtraction=True)
        for key in SOURCE_KEYS:info.pop(key,None)
        info.update(source_settings(cfg))
    else:
        for key in ('SUFeedURL','SUPublicEDKey','SURequireSignedFeed','SUVerifyUpdateBeforeExtraction')+SOURCE_KEYS:info.pop(key,None)
    info['SUEnableInstallerLauncherService']=True
    p.write_bytes(plistlib.dumps(info))
    (app/'Contents/Resources/Sparkle-LICENSE.txt').write_bytes((root/'.build/artifacts/sparkle/Sparkle/LICENSE').read_bytes())

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('app',type=Path);p.add_argument('--config',type=Path)
    a=p.parse_args();root=Path(__file__).resolve().parents[1]
    stage(a.app,root,a.config or root/'SharedResources/Updates/config.json')
