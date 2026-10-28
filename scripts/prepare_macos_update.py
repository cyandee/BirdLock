"""Prepare signed Sparkle feeds and deltas locally. Does not publish files."""
from pathlib import Path
from urllib.parse import urlsplit
import argparse,copy,shutil,subprocess,xml.etree.ElementTree as ET

SPARKLE='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',SPARKLE)

def https_prefix(value):
    url=urlsplit(value)
    if url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('An HTTPS directory URL without credentials, query or fragment is required')

def retain_stable(new_feed,previous_feed):
    """Only merge feeds verified by sign_update; re-sign the result afterwards."""
    root=ET.parse(new_feed);channel=root.find('channel')
    previous=ET.parse(previous_feed)
    items=previous.findall('./channel/item')
    stable=[i for i in items if i.findtext(f'{{{SPARKLE}}}channel') in (None,'stable')]
    if stable:
        def version(item):return tuple(int(n) for n in item.findtext(f'{{{SPARKLE}}}version').split('.'))
        latest=max(stable,key=version)
        if version(latest)>=max(version(i) for i in channel.findall('item')):
            raise ValueError('The new numeric version must be newer than the previous stable version')
        channel.append(copy.deepcopy(latest))
        root.write(new_feed,encoding='utf-8',xml_declaration=True)

def prepare(archives,out,key_file,url_prefix,channel='beta',existing_feed=None):
    https_prefix(url_prefix)
    if channel not in ('stable','beta'):raise ValueError('Unknown update channel')
    root=Path(__file__).resolve().parents[1]
    tools=root/'.build/artifacts/sparkle/Sparkle/bin'
    if not (tools/'generate_appcast').is_file():raise ValueError('Resolve Sparkle before generating updates')
    if existing_feed:
        # Never re-sign unauthenticated entries from an old/remote feed.
        subprocess.run([str(tools/'sign_update'),'--verify','--ed-key-file',str(key_file),str(existing_feed)],check=True)
    out.mkdir(parents=True,exist_ok=False)
    for source in archives:
        if (out/source.name).exists():raise ValueError('Duplicate archive name')
        shutil.copy2(source,out/source.name)
    cmd=[str(tools/'generate_appcast'),'--ed-key-file',str(key_file),'--download-url-prefix',url_prefix.rstrip('/')+'/',
         '--maximum-versions','1','--maximum-deltas','5','-o',str(out/'macos.xml')]
    if channel=='beta':cmd+=['--channel','beta']
    subprocess.run(cmd+[str(out)],check=True)
    if existing_feed:
        def newest(path):
            return max(tuple(int(n) for n in item.findtext(f'{{{SPARKLE}}}version').split('.')) for item in ET.parse(path).findall('./channel/item'))
        if newest(existing_feed)>=newest(out/'macos.xml'):
            raise ValueError('Every release must increase the numeric version')
    if channel=='beta' and existing_feed:
        retain_stable(out/'macos.xml',existing_feed)
        subprocess.run([str(tools/'sign_update'),'--ed-key-file',str(key_file),str(out/'macos.xml')],check=True)
    subprocess.run([str(tools/'sign_update'),'--verify','--ed-key-file',str(key_file),str(out/'macos.xml')],check=True)
    return out/'macos.xml'

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('archives',nargs='+',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--key-file',type=Path,required=True);p.add_argument('--url-prefix',required=True);p.add_argument('--channel',choices=['stable','beta'],default='beta');p.add_argument('--initial-release',action='store_true');p.add_argument('--existing-feed',type=Path,help='Previously signed feed, required to retain the stable update when releasing a beta')
    a=p.parse_args()
    if a.channel=='beta' and not a.existing_feed and not a.initial_release:p.error('Pass --existing-feed, or --initial-release only when no feed has been published')
    prepare(a.archives,a.output,a.key_file,a.url_prefix,a.channel,a.existing_feed)
