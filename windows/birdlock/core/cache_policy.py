"""Bounded, conservative cleanup of rebuildable cache files; edit JSON is never removed."""
import json, re, time, threading, uuid
from contextlib import contextmanager
from pathlib import Path
from .workspace import path_from_url

_gate=threading.RLock()
_active={}
_operations={}
def protect(owner, paths):
    with _gate:
        if paths:_active[owner]={str(Path(p).resolve()) for p in paths}
        else:_active.pop(owner,None)
def begin(root):
    token=uuid.uuid4().hex
    with _gate:_operations[token]=str(Path(root).resolve())
    return token
def end(token):
    with _gate:_operations.pop(token,None)
@contextmanager
def operation(root):
    token=begin(root)
    try:yield token
    finally:end(token)

def total_size(root):
    total=0
    for p in Path(root).rglob('*'):
        try:
            if p.is_file() and not p.is_symlink():total+=p.stat().st_size
        except OSError:pass
    return total

def groups(root):
    root=Path(root);result=[]
    for directory in root.iterdir() if root.exists() else []:
        if directory.is_symlink() or not directory.is_dir():continue
        if directory.name=='video-imports':
            for video in directory.iterdir():
                if not re.fullmatch('[a-f0-9]{32}',video.name) or video.is_symlink():continue
                try:
                    recipe=json.loads((video/'video-recipe.json').read_text(encoding='utf-8'))
                    source=Path(recipe['sourcePath'])
                    if not source.is_file() or source.stat().st_size!=recipe['bytes']:continue
                    files=[p for p in video.iterdir() if re.fullmatch(r'video-\d{6}\.jpg|original-audio\.wav',p.name) and p.is_file() and not p.is_symlink()]
                    result.append((video,files,(video/'video-recipe.json').stat().st_mtime,{str(video)}))
                except (OSError,ValueError,KeyError):continue
        elif re.fullmatch('[a-f0-9]{24}',directory.name):
            try:
                data=json.loads((directory/'analysis.json').read_text(encoding='utf-8'));parents=set()
                for f in data['frames']:
                    source=Path(f.get('path') or path_from_url(f['url']));parents.add(str(source.parent))
                    if not source.is_file():
                        recipe=json.loads((source.parent/'video-recipe.json').read_text(encoding='utf-8'))
                        if not Path(recipe['sourcePath']).is_file():raise ValueError()
                files=[p for p in directory.glob('p*.jpg') if re.fullmatch(r'p\d{5,}\.jpg',p.name) and not p.is_symlink()]
                result.append((directory,files,(directory/'analysis.json').stat().st_mtime,parents))
            except (OSError,ValueError,KeyError):continue
        elif directory.name=='video-audio':
            for p in directory.glob('*.wav'):
                if re.fullmatch(r'[a-f0-9]{24,64}\.wav',p.name) and not p.is_symlink():result.append((directory,[p],p.stat().st_mtime,set()))
    return sorted(result,key=lambda x:x[2])

def _clean(root,limit_bytes=0,protected=(),only_videos=None):
    root=Path(root);before=total_size(root);remaining=before;removed=0;failures=0
    if only_videos is None and before<=limit_bytes:return dict(before=before,after=before,removed=0,failures=0,overLimit=False)
    protected={str(Path(p).resolve()) for p in protected}
    for active in _active.values():protected.update(active)
    for group,files,stamp,parents in groups(root):
        if only_videos is None and remaining<=limit_bytes:break
        if str(group.resolve()) in protected or {str(Path(p).resolve()) for p in parents} & protected:continue
        if only_videos is not None and group.name!='video-audio' and not ({str(Path(p).resolve()) for p in parents} & {str(Path(p).resolve()) for p in only_videos}):continue
        if group.parent.name=='video-imports' and files:
            try:(group/'.evicted.json').write_text('{"schema":1}',encoding='utf-8')
            except OSError:failures+=1;continue
        for p in files:
            try:
                size=p.stat().st_size;p.unlink();remaining-=size;removed+=size
            except OSError:failures+=1
    after=total_size(root)
    return dict(before=before,after=after,removed=removed,failures=failures,overLimit=after>limit_bytes if only_videos is None else False)

def clean(root,limit_bytes=0,protected=(),only_videos=None):
    with _gate:
        if str(Path(root).resolve()) in _operations.values():
            size=total_size(root)
            return dict(before=size,after=size,removed=0,failures=0,overLimit=size>limit_bytes)
        return _clean(root,limit_bytes,protected,only_videos)
