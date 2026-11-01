"""Versioned .birdlock documents, independent of disposable frame/proxy caches."""
from __future__ import annotations
import copy, json, os, tempfile
from pathlib import Path
from urllib.parse import urlparse, unquote
from .frames import SourceFrame,read_frame
from .analysis import SequenceAnalysis, build_track, fingerprint
from .subjects import SubjectProfile
from .settings import AudioSettings, WatermarkSettings

FORMAT='BirdLockProject'
SCHEMA=1
MAX_BYTES=128<<20

class MissingMedia(ValueError):
    def __init__(self, paths):
        self.paths=paths
        super().__init__('找不到工程素材：'+ '\n'.join(paths[:8]))

def path_from_url(value):
    if not value:return ''
    if value.startswith('file:'):
        parsed=urlparse(value);p=unquote(parsed.path)
        if parsed.netloc and parsed.netloc!='localhost':p='//'+parsed.netloc+p
        if os.name=='nt' and len(p)>2 and p[0]=='/' and p[2]==':':p=p[1:]
        return p
    return value

def uri(path):return Path(path).absolute().as_uri()

def native_analysis(a):
    d=copy.deepcopy(a.to_dict());d.pop('track',None)
    for f in d['frames']:f['url']=uri(f.pop('path'))
    for p in d['perFrame']:
        p['keypoints']=[dict(x=k[0],y=k[1],conf=k[2]) for k in p['keypoints']]
        if p.get('aircraft') and 'registration_quality' in p['aircraft']:p['aircraft']['registrationQuality']=p['aircraft'].pop('registration_quality')
    return d

def local_analysis(data):
    d=copy.deepcopy(data);d.pop('track',None)
    for f in d['frames']:f['path']=path_from_url(f.pop('url'));f.setdefault('orientation',1)
    for p in d['perFrame']:
        p['keypoints']=[(k['x'],k['y'],k['conf']) for k in p.get('keypoints',[])]
        p['head']['points']=[([v['x'],v['y']] if isinstance(v,dict) else v) if v is not None else None for v in p['head']['points']]
        p.setdefault('target',None);p.setdefault('sharpness',None);p.setdefault('link',None);p.setdefault('aircraft',None)
        if p['link'] and isinstance(p['link']['delta'],dict):p['link']['delta']=[p['link']['delta']['x'],p['link']['delta']['y']]
        if p.get('aircraft') and 'registrationQuality' in p['aircraft']:p['aircraft']['registration_quality']=p['aircraft'].pop('registrationQuality')
    d['manualEye']={k:((v['x'],v['y']) if isinstance(v,dict) else tuple(v)) for k,v in d.get('manualEye',{}).items()}
    a=SequenceAnalysis.from_dict(d);a.track=build_track(a);return a

def native_profile(profile):
    d=profile.to_dict()
    if d['selection'].get('trimEnd',-1)<0:d['selection']['trimEnd']=None
    return d

def local_profile(d):
    d=copy.deepcopy(d)
    if d.get('selection',{}).get('trimEnd') is None:d.setdefault('selection',{})['trimEnd']=-1
    return SubjectProfile.from_dict(d)

def native_audio(audio):
    d=audio.to_dict()
    for t in [d]+d.get('tracks',[]):
        path=t.pop('path','');t['url']=uri(path) if path else None
        if not t.get('assetID'):t['assetID']=None
        if not t.get('arrangementError'):t['arrangementError']=None
    return d

def local_audio(d):
    d=copy.deepcopy(d)
    for t in [d]+d.get('tracks',[]):
        t['path']=path_from_url(t.pop('url',None))
        t['assetID']=t.get('assetID') or '';t['arrangementError']=t.get('arrangementError') or ''
    return AudioSettings.from_dict(d)

def native_watermark(watermark):
    d=watermark.to_dict();d['imagePath']=d.get('imagePath') or None;return d

def local_watermark(data):
    d=copy.deepcopy(data);d['imagePath']=d.get('imagePath') or '';return WatermarkSettings.from_dict(d)

def create(*,frames,segments,analysis,remembered,subject,profile,profiles,audio,watermark,segment_index,merge_groups,current_frame,view_mode,source_zoom,preview_audio):
    master={f.path for f in frames};analyses=[analysis]
    for a in remembered:
        if a.fingerprint!=analysis.fingerprint and a.frames and all(f.path in master for f in a.frames):analyses.append(a)
    videos=[]
    for directory in dict.fromkeys(str(Path(f.path).parent) for f in frames):
        root=Path(directory);recipe=root/'video-recipe.json'
        if (root/'video-source.json').is_file():
            if not recipe.is_file():raise ValueError('请重新导入一次该视频，记录原片与镜头参数后再保存工程。')
            motion=root/'motion.json'
            videos.append(dict(cacheDirectory=directory,recipe=json.loads(recipe.read_text(encoding='utf-8')),motion=json.loads(motion.read_text(encoding='utf-8')) if motion.exists() else None))
    return dict(format=FORMAT,schema=SCHEMA,creatorVersion='1.9.0',subject=subject,frames=[{**f.to_dict(),'url':uri(f.path)} for f in frames],
        segments=[dict(start=s.start,count=s.count,fps=s.fps) for s in segments],segmentIndex=segment_index,mergeGroups=list(merge_groups),
        analyses=[native_analysis(a) for a in analyses],profile=native_profile(profile),profiles={k:native_profile(v) for k,v in profiles.items()},
        audio=native_audio(audio),watermark=native_watermark(watermark),videos=videos,currentFrame=current_frame,viewMode=view_mode,sourceZoom=source_zoom,previewAudio=preview_audio)

def save(document, path, cache_root):
    path=Path(path).absolute();cache_root=Path(cache_root).resolve()
    if path.resolve().is_relative_to(cache_root):raise ValueError('工程文件请保存在缓存文件夹之外。')
    d=copy.deepcopy(document)
    for f in d['frames']:f.pop('path',None)
    video_dirs={v['cacheDirectory'] for v in d['videos']};paths={}
    for f in d['frames']:
        p=path_from_url(f['url'])
        if str(Path(p).parent) not in video_dirs:paths[p]=True
    for v in d['videos']:paths[v['recipe']['sourcePath']]=True
    for t in [d['audio']]+d['audio'].get('tracks',[]):
        if t.get('url') and not t.get('videoOriginal'):paths.setdefault(path_from_url(t['url']),False)
    if d['watermark'].get('imagePath'):paths.setdefault(d['watermark']['imagePath'],False)
    d['locations']=[]
    for p,required in paths.items():
        file=Path(p)
        try:relative=os.path.relpath(file,path.parent)
        except ValueError:relative=''
        d['locations'].append(dict(path=p,relative=relative,bytes=file.stat().st_size if file.is_file() else None,required=required))
    raw=json.dumps(d,ensure_ascii=False,allow_nan=False,separators=(',',':')).encode('utf-8')
    if len(raw)>MAX_BYTES:raise ValueError('工程过大，请拆分素材后保存。')
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'-',suffix='.tmp',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def read(path, relocation=None):
    path=Path(path)
    if path.stat().st_size>MAX_BYTES:raise ValueError('工程文件超出支持大小。')
    d=json.loads(path.read_text(encoding='utf-8'))
    if d.get('format')!=FORMAT or d.get('schema')!=SCHEMA:raise ValueError('不支持的工程格式或版本。')
    if not d.get('frames') or len(d['frames'])>100000 or not d.get('analyses'):raise ValueError('工程缺少有效画面或识别记录。')
    if d.get('subject') not in ('bird','aircraft'):raise ValueError('工程主体类型无效。')
    missing=[];mapping={};warnings=[]
    for loc in d.get('locations',[]):
        original=loc['path'];name=original.replace('\\','/').rsplit('/',1)[-1]
        candidates=[Path(original),path.parent/loc['relative'].replace('\\','/')]
        if relocation:candidates.extend([Path(relocation)/name,Path(relocation)/loc['relative']])
        candidate=next((p for p in candidates if p.is_file() and (loc.get('bytes') is None or p.stat().st_size==loc['bytes'])),None)
        if candidate:mapping[original]=str(candidate.resolve())
        elif loc.get('required',True):missing.append(original)
        else:warnings.append(name)
    if missing:raise MissingMedia(missing)
    d=replace_paths(d,mapping)
    n=len(d['frames'])
    for seg in d['segments']:
        if not 0<=seg['start']<seg['start']+seg['count']<=n or not 0<seg['fps']<=1000:raise ValueError('工程分组范围无效。')
    master={f['url'] for f in d['frames']}
    for a in d['analyses']:
        if any(f['url'] not in master for f in a['frames']):raise ValueError('工程识别记录引用了其他素材。')
        for i,frame in enumerate(a['perFrame']):
            if frame['index']!=i or len(frame['head']['points'])!=6 or len(frame['head']['conf'])!=6:raise ValueError('工程头部记录不完整。')
            target=frame.get('target')
            if target is not None and not 0<=target<len(frame['birds']):raise ValueError('工程主体编号无效。')
        for shot in a.get('closeups',[]):
            if not 0<=shot['frame']<=shot.get('endFrame',shot['frame'])<len(a['frames']) or not 0<shot['seconds']<=3600:raise ValueError('工程特写范围无效。')
        if len(a['frames'])!=len(a['perFrame']) or not a['frames'] or not 0<a['fps']<=1000:raise ValueError('工程识别记录不完整。')
        if any(not 0<=int(i)<len(a['frames']) for i in list(a.get('manualEye',{}))+a.get('excluded',[])):raise ValueError('工程编辑帧编号无效。')
    index=d['segmentIndex'];order=d['mergeGroups']
    if index!=-1 and not 0<=index<len(d['segments']):raise ValueError('工程分组选择无效。')
    if len(set(order))!=len(order) or any(not 0<=i<len(d['segments']) for i in order):raise ValueError('工程合并顺序无效。')
    selected=[d['segments'][i] for i in order] if index==-1 else [d['segments'][index]]
    expected=[f['url'] for s in selected for f in d['frames'][s['start']:s['start']+s['count']]]
    if expected!=[f['url'] for f in d['analyses'][0]['frames']] or d['analyses'][0].get('subject','bird')!=d['subject']:raise ValueError('工程当前画面与识别记录不匹配。')
    d['_warnings']=warnings
    return d

def wire_key(path):
    path=path.replace("\\","/")
    if len(path)>3 and path[0]=="/" and path[2]==":":path=path[1:]
    return path

def replace_paths(value, mapping):
    normal={wire_key(k):v for k,v in mapping.items()}
    def walk(value):
        if isinstance(value,dict):return {k:walk(v) for k,v in value.items()}
        if isinstance(value,list):return [walk(v) for v in value]
        if isinstance(value,str):
            p=wire_key(path_from_url(value))
            if p in normal:return uri(normal[p]) if value.startswith('file:') else normal[p]
        return value
    return walk(value)


def restore_media(document, cache_root, cancelled=lambda:False):
    from .video_import import extract
    from .video_stabilization import save_record,prepare
    d=copy.deepcopy(document);replacements={};metadata={}
    for video in d['videos']:
        r=video['recipe']
        with tempfile.TemporaryDirectory(prefix='birdlock-project-') as temp:
            profile=None
            if r.get('lensJSON'):
                profile=str(Path(temp)/'lens.json');Path(profile).write_text(r['lensJSON'],encoding='utf-8')
            frames,fps=extract(r['sourcePath'],r['start'],r['seconds'],r['fps'],profile=profile,root=Path(cache_root)/'video-imports',cancelled=cancelled)
        if len(frames)!=r['count']:raise ValueError('原视频已变化，不能恢复同一组画面。')
        if video.get('motion'):save_record(Path(frames[0].path).parent/'motion.json',video['motion'])
        else:prepare(frames,r['sourcePath'],r['start'],fps,cancelled=cancelled)
        old=video['cacheDirectory']
        for f in d['frames']:
            p=path_from_url(f['url'])
            if wire_key(str(Path(p).parent))==wire_key(old):
                ordinal=int(Path(p).stem.rsplit('-',1)[1]);new=frames[ordinal]
                if new.pixelWidth!=f['pixelWidth'] or new.pixelHeight!=f['pixelHeight']:raise ValueError('原视频画面尺寸已变化。')
                replacements[p]=new.path;metadata[new.path]=new
    d=replace_paths(d,replacements)
    for f in d['frames']+[f for a in d['analyses'] for f in a['frames']]:
        if path_from_url(f['url']) in metadata:
            new=metadata[path_from_url(f['url'])];f['fileSize']=new.fileSize;f['modified']=new.modified
    orientations={}
    for f in d['frames']+[f for a in d['analyses'] for f in a['frames']]:
        if 'orientation' not in f:
            path=path_from_url(f['url'])
            if path not in orientations:
                original=read_frame(path,f['id'])
                if original is None:raise ValueError('工程素材无法解码：'+path)
                if (original.pixelWidth,original.pixelHeight)!=(f['pixelWidth'],f['pixelHeight']):raise ValueError('工程素材画面尺寸已变化。')
                orientations[path]=original.orientation
            f['orientation']=orientations[path]
    frames=[]
    for f in d['frames']:
        f=dict(f);f['path']=path_from_url(f.pop('url'));f.setdefault('orientation',1);frames.append(SourceFrame.from_dict(f))
    analyses=[local_analysis(a) for a in d['analyses']]
    for a in analyses:a.fingerprint=fingerprint(a.frames,a.subject,a.modelIdentity)
    d['_frames']=frames;d['_analyses']=analyses
    return d
