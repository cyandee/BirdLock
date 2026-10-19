"""Offline energy/onset suggestions; the user chooses the actual musical alignment."""
import numpy as np


def analyze(peaks, rate=40):
    p=np.nan_to_num(np.maximum(0,np.asarray(peaks,dtype=float)),nan=0,posinf=0,neginf=0)
    if len(p)<=8 or rate<=0 or np.ptp(p)<=0.025:return []
    onset=np.array([max(0,p[i]-(np.mean(p[max(0,i-4):i]) if i else 0)) for i in range(len(p))])
    beats=[]
    for i in np.argsort(-onset,kind="stable"):
        if onset[i]<=max(0.035,p.mean()*0.15):break
        if all(abs(int(i)-j)>=int(rate*0.25) for j in beats):beats.append(int(i))
        if len(beats)>=160:break
    radius=max(1,int(rate));prefix=np.r_[0,np.cumsum(p*p)]
    energy=np.array([(prefix[min(len(p),i+radius+1)]-prefix[max(0,i-radius)])/(min(len(p),i+radius+1)-max(0,i-radius)) for i in range(len(p))])
    highlights=[]
    for i in np.argsort(-energy,kind="stable"):
        if energy[i]<=np.mean(p*p)*1.15:break
        if all(abs(int(i)-j)>=int(rate*5) for j in highlights):highlights.append(int(i))
        if len(highlights)>=3:break
    return sorted([{"time":i/rate,"climax":False} for i in beats]+[{"time":i/rate,"climax":True} for i in highlights],key=lambda c:c["time"])


def visual_candidates(analysis, included=None):
    if analysis is None or analysis.track is None:return []
    sharp=np.median([p.sharpness for p in analysis.perFrame if p.sharpness is not None] or [1])
    scores=[]
    for i,p in enumerate(analysis.perFrame):
        box=p.target_box
        if (included is not None and i not in included) or i in analysis.excluded or box is None or not analysis.track.has_data[i]:scores.append(0);continue
        spread=np.sqrt(max(1,box.w*box.h))/max(1,analysis.track.head_length[i])
        scores.append(np.clip((p.sharpness if p.sharpness is not None else sharp)/max(1,sharp),0.1,2)*np.clip(spread,1,12)*analysis.track.confidence[i])
    chosen=[]
    for i in np.argsort(-np.array(scores),kind="stable"):
        if scores[i]<=0:break
        if all(abs(int(i)-j)>=max(1,analysis.count//8) for j in chosen):chosen.append(int(i))
        if len(chosen)==3:break
    return sorted(chosen)
