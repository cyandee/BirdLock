"""Single shutter events derived from the final edited timeline, shared by export and preview."""
from .settings import AudioTrack
from .sounds import assets


def mute_bursts(audio, frames, fps):
    result = audio.copy()
    ranges = []
    for frame in frames:
        if frame.closeup < 0: continue
        end = frame.time + 1 / fps
        if ranges and abs(ranges[-1][1] - frame.time) < 1e-7:
            ranges[-1][1] = end
        else: ranges.append([frame.time, end])
    from .sounds import asset_path
    burst_paths = {asset_path(a['id']) for a in assets() if a['kind'] == 'burst'}
    for track in [result, *result.tracks]:
        if track.assetID and asset_path(track.assetID) in burst_paths:
            track.muteRanges = [list(r) for r in track.muteRanges] + [list(r) for r in ranges]
    return result


def audible_ranges(track, start, end):
    import math
    spans = [[start, end]]
    for r in track.muteRanges:
        if len(r) != 2 or not all(math.isfinite(v) for v in r) or r[0] >= r[1]: continue
        updated = []
        for a, b in spans:
            if r[1] <= a or r[0] >= b: updated.append([a, b]); continue
            updated += [[x, y] for x, y in [(a, min(b, r[0])), (max(a, r[1]), b)] if x < y]
        spans = updated
    return spans


def tracks(frames, closeups, fps=30):
    result=[]; previous=None
    duration=next((e["duration"] for e in assets() if e["id"]=="single-canon-rebel"),0.232)
    for i,f in enumerate(frames):
        if 0 <= f.closeup < len(closeups) and closeups[f.closeup].shutterEnabled and (previous is None or previous.closeup!=f.closeup or previous.audioCycle!=f.audioCycle):
            shot=closeups[f.closeup]
            end=i+1
            while end<len(frames) and frames[end].closeup==f.closeup and frames[end].audioCycle==f.audioCycle:end+=1
            result.append(AudioTrack(assetID="single-canon-rebel",timelineStart=f.time,duration=min(duration,(end-i)/fps),volume=max(0,min(1.5,shot.shutterVolume)),loop=False,fadeIn=0,fadeOut=0))
        previous=f
    return result


def gain(tracks, duration):
    events={}
    for t in tracks:
        start=max(0,t.timelineStart);end=min(duration,start+t.duration if t.duration>0 else duration)
        if not t.active or start>=end:continue
        volume=max(0,min(2,t.volume))
        for a,b in audible_ranges(t,start,end):
            events[a]=events.get(a,0)+volume;events[b]=events.get(b,0)-volume
    level=0;peak=1
    for time in sorted(events):level+=events[time];peak=max(peak,level)
    return 1/peak
