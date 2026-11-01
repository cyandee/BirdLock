import json, tempfile, unittest, os
from pathlib import Path
from unittest.mock import patch
import cv2
import numpy as np
from birdlock.core import workspace, cache_policy
from birdlock.core.frames import SourceFrame,BurstSegment,ExifInfo
from birdlock.core.analysis import SequenceAnalysis,FrameAnalysis,Box,ProxyCache,build_track,fingerprint
from birdlock.core.models import PoseSchema
from birdlock.core.subjects import SubjectProfile
from birdlock.core.settings import Composition,LookSettings,ExportSettings,FrameSelection,AudioSettings,AudioTrack,WatermarkSettings,Closeup

def example(root,count=6):
    root=Path(root);root.mkdir(parents=True,exist_ok=True);frames=[]
    for i in range(count):
        path=root/f'鸟 {i}.jpg';cv2.imencode('.jpg',np.full((48,64,3),50+i,np.uint8))[1].tofile(str(path));stat=path.stat()
        frames.append(SourceFrame(i,str(path),64,48,captureTime=i/30,fileSize=stat.st_size,modified=stat.st_mtime,exif=ExifInfo()))
    a=SequenceAnalysis(fingerprint(frames),frames,30,64,[FrameAnalysis(i,birds=[Box(10,10,30,20,.9)],target=0) for i in range(count)],PoseSchema([]))
    a.manualEye={2:(26.25,21.5)};a.excluded={1};shot=Closeup(frame=3,endFrame=4,seconds=.5,zoom=2);a.closeups=[shot];a.track=build_track(a)
    p=SubjectProfile(Composition(),LookSettings(),ExportSettings(),FrameSelection(trimStart=1,trimEnd=5),'lead')
    p.look.stabilization.maxZoom=6
    return workspace.create(frames=frames,segments=[BurstSegment(0,count,30)],analysis=a,remembered=[],subject='bird',profile=p,profiles={'bird':p},audio=AudioSettings(),watermark=WatermarkSettings(),segment_index=0,merge_groups=[0],current_frame=3,view_mode='source',source_zoom=4,preview_audio=True)

class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name);self.cache=self.root/'cache';self.cache.mkdir()
    def test_optional_empty_strings_stay_absent_in_shared_audio_and_watermark(self):
        audio=AudioSettings(tracks=[AudioTrack(assetID='sony-20')])
        wire=workspace.native_audio(audio)
        self.assertIsNone(wire['tracks'][0]['arrangementError'])
        self.assertEqual(workspace.local_audio(wire).tracks[0].arrangementError,'')
        self.assertIsNone(workspace.native_watermark(WatermarkSettings())['imagePath'])
        self.assertEqual(workspace.local_watermark({'imagePath':None}).imagePath,'')
    def test_shared_wire_encoding_does_not_mutate_live_registration_observations(self):
        d=example(self.root/'media');a=workspace.local_analysis(d['analyses'][0])
        a.perFrame[1].link=dict(delta=[1.25,-2.5],quality=.9,patchScale=1.)
        wire=workspace.native_analysis(a)
        self.assertEqual(a.perFrame[1].link['delta'],[1.25,-2.5])
        self.assertEqual(wire['perFrame'][1]['link']['delta'],[1.25,-2.5])
        self.assertEqual(workspace.local_analysis(wire).perFrame[1].link['delta'],[1.25,-2.5])
    def test_project_survives_proxy_cleanup_and_preserves_all_edits(self):
        d=example(self.root/'素材');file=self.root/'工程.birdlock';workspace.save(d,file,self.cache)
        restored=workspace.restore_media(workspace.read(file),self.cache);a=restored['_analyses'][0]
        self.assertEqual(a.manualEye,{2:(26.25,21.5)});self.assertEqual(a.excluded,{1});self.assertEqual(a.closeups[0].endFrame,4)
        p=workspace.local_profile(restored['profile']);self.assertEqual(p.selection.trimEnd,5);self.assertEqual(p.look.stabilization.maxZoom,6)
        cache=ProxyCache(self.cache);cache.save_analysis(a);self.assertIsNotNone(cache.load_proxy(a.fingerprint,2))
        cached=self.cache/a.fingerprint/'analysis.json';before=cached.read_bytes()
        report=cache_policy.clean(self.cache,0)
        self.assertGreater(report['removed'],0);self.assertEqual(cached.read_bytes(),before)
        self.assertIsNotNone(cache.load_analysis(a.fingerprint));self.assertIsNotNone(cache.load_proxy(a.fingerprint,2))
        self.assertTrue(file.is_file())
    def test_relocation_and_wrong_size_do_not_silently_replace_media(self):
        d=example(self.root/'old');file=self.root/'project.birdlock';workspace.save(d,file,self.cache)
        (self.root/'old').rename(self.root/'new')
        with self.assertRaises(workspace.MissingMedia):workspace.read(file)
        loaded=workspace.read(file,self.root/'new');self.assertIn('/new/',workspace.path_from_url(loaded['frames'][0]['url']))
        (self.root/'new'/'鸟 0.jpg').write_bytes(b'wrong')
        with self.assertRaises(workspace.MissingMedia):workspace.read(file,self.root/'new')
    def test_atomic_failure_keeps_previous_project(self):
        d=example(self.root/'media');file=self.root/'project.birdlock';workspace.save(d,file,self.cache);original=file.read_bytes()
        with patch('birdlock.core.workspace.os.replace',side_effect=OSError('disk full')):
            with self.assertRaises(OSError):workspace.save(d,file,self.cache)
        self.assertEqual(file.read_bytes(),original)
        with self.assertRaises(ValueError):workspace.save(d,self.cache/'project.birdlock',self.cache)
    def test_schema_and_invalid_edits_are_rejected(self):
        d=example(self.root/'media');file=self.root/'bad.birdlock';workspace.save(d,file,self.cache)
        raw=json.loads(file.read_text(encoding="utf-8"));raw['schema']=999;file.write_text(json.dumps(raw))
        with self.assertRaises(ValueError):workspace.read(file)
        raw['schema']=1;raw['analyses'][0]['manualEye']={'999':dict(x=1,y=2)};file.write_text(json.dumps(raw))
        with self.assertRaises(ValueError):workspace.read(file)
    def test_native_photo_orientation_is_recovered_from_original(self):
        from PIL import Image
        d=example(self.root/'portrait')
        for f in d['frames']:
            path=Path(workspace.path_from_url(f['url']));image=Image.new('RGB',(64,48),'green');exif=image.getexif();exif[274]=6;image.save(path,exif=exif)
        for f in d['frames']+[f for a in d['analyses'] for f in a['frames']]:
            f.pop('orientation',None);f['pixelWidth'],f['pixelHeight']=48,64
        file=self.root/'portrait.birdlock';workspace.save(d,file,self.cache)
        restored=workspace.restore_media(workspace.read(file),self.cache)
        self.assertTrue(all(f.orientation==6 for f in restored['_frames']))
        self.assertTrue(all(f.orientation==6 for f in restored['_analyses'][0].frames))
    def test_group_records_and_custom_order_survive_save(self):
        import copy
        d=example(self.root/'groups',12);original=d['analyses'][0];parts=[]
        for start in (0,6):
            a=copy.deepcopy(original);a['frames']=a['frames'][start:start+6];a['perFrame']=a['perFrame'][start:start+6]
            for i,p in enumerate(a['perFrame']):p['index']=i
            a['manualEye']={'2':[26.25,21.5]};parts.append(a)
        active=copy.deepcopy(original);active['frames']=active['frames'][6:]+active['frames'][:6];active['perFrame']=active['perFrame'][6:]+active['perFrame'][:6]
        for i,p in enumerate(active['perFrame']):p['index']=i
        d.update(segments=[dict(start=0,count=6,fps=30),dict(start=6,count=6,fps=30)],segmentIndex=-1,mergeGroups=[1,0],analyses=[active]+parts)
        file=self.root/'groups.birdlock';workspace.save(d,file,self.cache)
        restored=workspace.restore_media(workspace.read(file),self.cache)
        self.assertEqual(restored['mergeGroups'],[1,0]);self.assertEqual(len(restored['_analyses']),3)
        self.assertEqual(Path(restored['_analyses'][0].frames[0].path).resolve(),Path(workspace.path_from_url(d['frames'][6]['url'])).resolve())
        self.assertEqual(restored['_analyses'][2].manualEye[2],(26.25,21.5))
    def group(self,token,size,stamp):
        video=self.cache/'video-imports'/token;video.mkdir(parents=True)
        source=self.root/(token+'.mp4');source.write_bytes(b'original')
        recipe=dict(sourcePath=str(source),bytes=8,modified=stamp,width=64,height=48,start=0,seconds=1,fps=1,count=1,lensJSON=None)
        (video/'video-recipe.json').write_text(json.dumps(recipe));os.utime(video/'video-recipe.json',(stamp,stamp))
        (video/'video-000000.jpg').write_bytes(b'x'*size);(video/'motion.json').write_text('{"keep":"gyro"}')
        return video,source
    def test_lru_quota_preserves_active_originals_metadata_and_documents(self):
        old,source=self.group('a'*32,1000,1);current,_=self.group('b'*32,1000,2)
        doc=self.root/'project.birdlock';doc.write_text('keep')
        report=cache_policy.clean(self.cache,cache_policy.total_size(self.cache)-900,{str(current)})
        self.assertFalse((old/'video-000000.jpg').exists());self.assertTrue((current/'video-000000.jpg').exists())
        self.assertEqual((old/'motion.json').read_text(encoding="utf-8"),'{"keep":"gyro"}');self.assertTrue((old/'.evicted.json').is_file())
        self.assertEqual(source.read_bytes(),b'original');self.assertEqual(doc.read_text(encoding="utf-8"),'keep');self.assertGreater(report['removed'],0)
    def test_busy_lease_and_dynamic_active_protection_override_old_cleanup_snapshot(self):
        current,_=self.group('e'*32,1000,1)
        with cache_policy.operation(self.cache):
            self.assertEqual(cache_policy.clean(self.cache,0)['removed'],0)
        cache_policy.protect('test-owner',[current])
        try:self.assertEqual(cache_policy.clean(self.cache,0)['removed'],0)
        finally:cache_policy.protect('test-owner',[])
        self.assertGreater(cache_policy.clean(self.cache,0)['removed'],0)
    def test_protected_over_limit_reports_and_unknown_or_symlink_is_never_deleted(self):
        current,_=self.group('c'*32,1000,1)
        external=self.root/'outside';external.mkdir();(external/'video-000000.jpg').write_bytes(b'keep')
        (self.cache/'video-imports'/('d'*32)).symlink_to(external,target_is_directory=True)
        report=cache_policy.clean(self.cache,0,{str(current)})
        self.assertTrue(report['overLimit']);self.assertTrue((current/'video-000000.jpg').is_file());self.assertEqual((external/'video-000000.jpg').read_bytes(),b'keep')
