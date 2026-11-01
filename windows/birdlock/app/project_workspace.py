"""Project persistence and cache lifecycle, shared by UI entry points and regression probes."""
import threading
from pathlib import Path
from ..core import workspace, cache_policy, frames as F
from ..core.subjects import SubjectProfile

class ProjectWorkspace:
    def init_workspace(self):
        self.project_path='';self.project_dirty=False;self._project_loading=False
        self.cache_limit_gb=20;self.ask_cleanup_after_export=True
        self.cleanup_export_token=0;self.last_export_kind=''
        self.cache_message='';self._cache_owner=str(id(self))

    def project_snapshot(self):
        if self.analysis is None or self.phase!='ready':raise ValueError('请先完成导入和分析，再保存工程。')
        self._analysis_save_timer.stop();self.cache.save_analysis(self.analysis.copy_edits())
        profiles=dict(self._subject_profiles);profiles[self.subject]=self._profile()
        with self.cache._record_lock:remembered=list(self.cache.records.values())
        return workspace.create(frames=self.frames,segments=self.segments,analysis=self.analysis,remembered=remembered,subject=self.subject,
            profile=self._profile(),profiles=profiles,audio=self.audio,watermark=self.watermark,segment_index=self.segment_index,
            merge_groups=self.merge_group_indices,current_frame=self.current_frame,view_mode=self.view_mode,source_zoom=self.source_zoom,preview_audio=self.preview_audio)

    def save_project(self,path):
        workspace.save(self.project_snapshot(),path,self.cache.root)
        self.project_path=str(Path(path).absolute());self.project_dirty=False;self.changed.emit('project')

    def open_project(self,path,document=None,relocation=None):
        document=document or workspace.read(path,relocation)
        self.stop();self._cancel.cancel();self._import_gen+=1
        from ..core.analysis import Cancelled
        from .state import CancelFlag
        gen=self._import_gen;flag=CancelFlag();self._cancel=flag
        self.phase='importing';self.message='正在打开工程，按需恢复过程文件…';self.changed.emit('phase')
        def work():
            lease=cache_policy.begin(self.cache.root)
            try:
                d=workspace.restore_media(document,self.cache.root,cancelled=lambda:flag.cancelled)
                def done():
                    if gen!=self._import_gen or flag.cancelled:
                        cache_policy.end(lease);return
                    self._project_loading=True
                    try:
                        self.frames=d['_frames'];self.cache.retain_records(self.frames);self.segments=[F.BurstSegment(s['start'],s['start']+s['count'],s['fps']) for s in d['segments']]
                        self.segment_index=d['segmentIndex'];self.merge_group_indices=list(d['mergeGroups'])
                        for a in d['_analyses']:self.cache.save_analysis(a)
                        self.analysis=d['_analyses'][0];self.subject=d['subject']
                        self._subject_profiles={k:workspace.local_profile(v) for k,v in d['profiles'].items()}
                        self._apply_profile(workspace.local_profile(d['profile']),reset_trim=False)
                        self.audio=workspace.local_audio(d['audio']);self.watermark=workspace.local_watermark(d['watermark']);self._load_watermark_image()
                        self.current_frame=max(0,min(d['currentFrame'],self.analysis.count-1));self.view_mode=d['viewMode'];self.source_zoom=d['sourceZoom']
                        self.preview_audio=d['previewAudio'];self.source_tool='none';self._subject_rollback=None
                        self.phase='ready';self.project_path=str(Path(path).absolute());self.project_dirty=False
                        self.timeline_message='工程已恢复，可继续编辑。'+('部分音频或水印素材缺失，请重新选择。' if d.get('_warnings') else '')
                        self.engine.clear();self._rebuild_now();self._load_audio_overview()
                        self.save_settings();self.changed.emit('project');self.changed.emit('frames');self.changed.emit('analysis');self.changed.emit('audio');self.changed.emit('phase')
                        cache_policy.protect(self._cache_owner,self.protected_cache())
                    finally:
                        self._project_loading=False;cache_policy.end(lease)
                    self.trim_cache()
                if self._closing:cache_policy.end(lease)
                else:self.on_main(done)
            except Exception as error:
                cache_policy.end(lease)
                message=str(error)
                def failed():
                    if gen!=self._import_gen or flag.cancelled:return
                    self.phase='ready' if self.analysis is not None else 'empty';self.message=message;self.timeline_message=message
                    self.changed.emit('phase');self.changed.emit('analysis')
                self.on_main(failed)
        threading.Thread(target=work,daemon=True).start()

    def close_project(self):
        self.stop();self._cancel.cancel();self._import_gen+=1;self._job_gen+=1
        for timer in (self._rebuild_timer,self._analysis_save_timer,self._hires_timer,self._audio_rebuild_timer):timer.stop()
        self.frames=[];self.segments=[];self.merge_group_indices=[];self.analysis=self.job=None
        self.preview_image=self.source_image=self.source_detail=None;self.engine.clear()
        self.audio.tracks=[t for t in self.audio.tracks if not t.videoOriginal]
        self.cache.retain_records([]);cache_policy.protect(self._cache_owner,[])
        self.phase='empty';self.project_path='';self.project_dirty=False;self._subject_rollback=None
        self.changed.emit('project');self.changed.emit('frames');self.changed.emit('phase')

    def protected_cache(self):
        protected={str(Path(f.path).parent) for f in self.frames}
        if self.analysis:protected.add(str(self.cache.root/self.analysis.fingerprint));protected.add(str(self.cache.root/'video-audio'))
        return protected

    def trim_cache(self):
        cache_policy.protect(self._cache_owner,self.protected_cache())
        if not self.cache_limit_gb:return
        protected=self.protected_cache();limit=int(self.cache_limit_gb)*(1<<30)
        def work():
            report=cache_policy.clean(self.cache.root,limit,protected)
            def done():
                self.cache_message=('当前任务或保留记录超过缓存上限，可在关闭工程后清理。' if report['overLimit'] else f'缓存占用 {report["after"]/(1<<30):.2f} GB')
                self.changed.emit('cache')
            self.on_main(done)
        threading.Thread(target=work,daemon=True).start()

    def clean_current_video(self):
        roots={str(Path(f.path).parent) for f in self.frames if (Path(f.path).parent/'video-recipe.json').is_file()}
        self.close_project()
        return cache_policy.clean(self.cache.root,only_videos=roots)
