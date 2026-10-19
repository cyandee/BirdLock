"""Single shutter events derived from the final edited timeline, shared by export and preview."""
from .settings import AudioTrack
from .sounds import assets


def tracks(frames, closeups):
    result=[]; previous=None
    duration=next((e["duration"] for e in assets() if e["id"]=="single-canon-rebel"),0.232)
    for f in frames:
        if 0 <= f.closeup < len(closeups) and closeups[f.closeup].shutterEnabled and (previous is None or previous.closeup!=f.closeup or previous.audioCycle!=f.audioCycle):
            shot=closeups[f.closeup]
            result.append(AudioTrack(assetID="single-canon-rebel",timelineStart=f.time,duration=duration,volume=max(0,min(1.5,shot.shutterVolume)),loop=False,fadeIn=0,fadeOut=0))
        previous=f
    return result


def gain(tracks, duration):
    events={}
    for t in tracks:
        start=max(0,t.timelineStart);end=min(duration,start+t.duration if t.duration>0 else duration)
        if not t.active or start>=end:continue
        volume=max(0,min(2,t.volume))
        events[start]=events.get(start,0)+volume;events[end]=events.get(end,0)-volume
    level=0;peak=1
    for time in sorted(events):level+=events[time];peak=max(peak,level)
    return 1/peak
