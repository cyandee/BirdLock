"""Reorder complete, independently analysed bursts without losing photo edits."""
from dataclasses import replace
from .analysis import fingerprint, build_track


def reorder(analysis, order):
    clips=analysis.clips
    if not analysis.groupedDetection or len(order)!=len(clips) or set(order)!=set(range(len(clips))) or len(analysis.perFrame)!=analysis.count:
        raise ValueError("片段顺序与当前分析不匹配，请等待分析完成后再试。")
    cursor=0
    for clip in clips:
        if clip['start']!=cursor or clip['count']<=0:raise ValueError("片段范围无效。")
        cursor+=clip['count']
    if cursor!=analysis.count:raise ValueError("片段范围与照片不匹配。")
    for shot in analysis.closeups:
        if not any(c['start']<=shot.frame<=shot.endFrame<c['start']+c['count'] for c in clips):
            raise ValueError("特写跨越连拍组，请将特写范围调整到一组内再排序。")
    indices=[i for k in order for i in range(clips[k]['start'],clips[k]['start']+clips[k]['count'])]
    remap={old:new for new,old in enumerate(indices)}
    a=analysis.copy_edits()
    a.frames=[replace(analysis.frames[i],id=n) for n,i in enumerate(indices)]
    a.perFrame=[replace(analysis.perFrame[i],index=n) for n,i in enumerate(indices)]
    a.manualEye={remap[k]:v for k,v in analysis.manualEye.items()};a.excluded={remap[k] for k in analysis.excluded}
    a.closeups=[replace(s,frame=remap[s.frame],endFrame=remap[s.endFrame]) for s in analysis.closeups]
    a.clips=[];cursor=0
    for k in order:
        c=clips[k];a.clips.append(dict(start=cursor,count=c['count'],fps=c['fps']));a.perFrame[cursor].link=None;cursor+=c['count']
    a.fingerprint=fingerprint(a.frames,a.subject,a.modelIdentity);a.track=build_track(a)
    return a,indices
