"""Local, model-free tracking of a textured region and an independent interior anchor."""
from __future__ import annotations
import math
from dataclasses import replace
import cv2
import numpy as np
from . import frames as F
from .analysis import (Box, Cancelled, FrameAnalysis, SequenceAnalysis, Track, ProxyCache,
                       _background_stats, fingerprint, build_track)
from .models import PoseSchema
from .util import fill_gaps
from .phasecorr import extract_exact,sharpness


def point(value):
    return np.array([value['x'],value['y']],float)


def valid_seed(seed, frames):
    try:
        i=seed['frame'];b=seed['box'];p=point(seed['anchor'])
        values=[b[k] for k in ('x','y','w','h')]+list(p)
        f=frames[i]
        return (isinstance(i,int) and not isinstance(i,bool) and 0<=i<len(frames)
                and all(math.isfinite(v) for v in values) and min(b['w'],b['h'])>=4
                and 0<=b['x']<b['x']+b['w']<=f.pixelWidth+.01
                and 0<=b['y']<b['y']+b['h']<=f.pixelHeight+.01
                and b['x']<=p[0]<b['x']+b['w'] and b['y']<=p[1]<b['y']+b['h'])
    except (KeyError,TypeError,IndexError,ValueError):
        return False


def _apply(matrix,p):
    return matrix[:2,:2]@p+matrix[:2,2]


def _patch(image,box):
    x,y,w,h=box
    matrix=np.array([[w/32,0,x],[0,h/32,y]],np.float32)
    return cv2.warpAffine(image,matrix,(32,32),flags=cv2.INTER_LINEAR|cv2.WARP_INVERSE_MAP).astype(np.float32)


def _correlation(a,b):
    a=a-a.mean();b=b-b.mean()
    den=float(np.linalg.norm(a)*np.linalg.norm(b))
    return float((a*b).sum()/den) if den>1e-3 else -1.


def _step(previous,current,box,anchor):
    """Feature consensus measures the local point, rather than replacing it with box centre."""
    gray=lambda im:cv2.cvtColor(im,cv2.COLOR_BGR2GRAY) if im.ndim==3 else im
    a,b=gray(previous),gray(current)
    if a.shape!=b.shape:return None
    x,y,w,h=box
    mask=np.zeros(a.shape,np.uint8)
    x0,y0=max(0,round(x)),max(0,round(y))
    x1,y1=min(a.shape[1],round(x+w)),min(a.shape[0],round(y+h))
    if x1-x0<4 or y1-y0<4:return None
    mask[y0:y1,x0:x1]=255
    corners=cv2.goodFeaturesToTrack(a,160,.012,max(2,min(w,h)/18),mask=mask,blockSize=3)
    matrix=None;quality=0.
    if corners is not None and len(corners)>=6:
        target,status,_=cv2.calcOpticalFlowPyrLK(a,b,corners,None,winSize=(31,31),maxLevel=4)
        if target is not None:
            back,status2,_=cv2.calcOpticalFlowPyrLK(b,a,target,None,winSize=(31,31),maxLevel=4)
            if back is not None:
                good=(status.ravel()!=0)&(status2.ravel()!=0)&(np.linalg.norm(back-corners,axis=2).ravel()<1.2)
                if good.sum()>=6:
                    fit,inliers=cv2.estimateAffinePartial2D(corners[good],target[good],method=cv2.RANSAC,ransacReprojThreshold=1.8)
                    if fit is not None and inliers is not None and inliers.mean()>=.65:
                        scale=math.hypot(fit[0,0],fit[1,0])
                        if .7<scale<1.4 and abs(math.atan2(fit[1,0],fit[0,0]))<.7:
                            matrix=np.vstack((fit,[0,0,1]));quality=float(inliers.mean())
    if matrix is None:
        # A bounded multi-scale search also works when the inter-photo displacement exceeds LK.
        template=a[y0:y1,x0:x1]
        if template.std()<3:return None
        pad=max(72,round(max(w,h)*2))
        sx,sy=max(0,x0-pad),max(0,y0-pad)
        search=b[sy:min(b.shape[0],y1+pad),sx:min(b.shape[1],x1+pad)]
        candidates=[]
        shrink=min(1.,640/max(search.shape))
        search=cv2.resize(search,None,fx=shrink,fy=shrink) if shrink<1 else search
        for scale in (.85,1.,1.18):
            tw,th=max(4,round(template.shape[1]*scale*shrink)),max(4,round(template.shape[0]*scale*shrink))
            if tw>=search.shape[1] or th>=search.shape[0]:continue
            t=cv2.resize(template,(tw,th))
            scores=cv2.matchTemplate(search,t,cv2.TM_CCOEFF_NORMED)
            _,score,_,loc=cv2.minMaxLoc(scores)
            if not math.isfinite(score):continue
            yy,xx=np.ogrid[:scores.shape[0],:scores.shape[1]]
            other=scores[(xx-loc[0])**2+(yy-loc[1])**2>max(4,min(tw,th)*.4)**2]
            runner=float(other.max()) if other.size else -1
            if score>.68 and (score-runner>.06 or runner<.5):
                tx=sx+loc[0]/shrink-scale*x0;ty=sy+loc[1]/shrink-scale*y0
                candidates.append((score,np.array([[scale,0,tx],[0,scale,ty],[0,0,1.]])))
        if not candidates:return None
        quality,matrix=max(candidates,key=lambda c:c[0])
    corners=np.array([[x,y],[x+w,y],[x+w,y+h],[x,y+h]])
    mapped=np.array([_apply(matrix,p) for p in corners])
    lo,hi=mapped.min(0),mapped.max(0);p=_apply(matrix,anchor)
    if (not np.isfinite(mapped).all() or not 0<=p[0]<b.shape[1] or not 0<=p[1]<b.shape[0]
            or min(hi-lo)<4 or lo.min()<0 or hi[0]>b.shape[1] or hi[1]>b.shape[0]):return None
    return matrix,np.r_[lo,hi-lo],p,quality


def retrack(analysis,cache=None,span=None,cancelled=lambda:False,progress=lambda p:None):
    if cancelled():raise Cancelled()
    cache=cache or ProxyCache();a=analysis.copy_edits();a.perFrame=[replace(p) for p in a.perFrame]
    ranges=[range(c['start'],c['start']+c['count']) for c in a.clips] or [range(a.count)]
    selected=[r for r in ranges if span is None or r.start==span.start]
    total_frames=max(1,sum(len(r) for r in selected));finished=set();progress(0)
    def mark(i):
        finished.add(i);progress(len(finished)/total_frames)
    def statistics(image,box,anchor,i):
        a.perFrame[i].bgLinear=_background_stats(image,box)
        side=round(max(16,min(384,min(box[2:]))))
        gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
        patch=extract_exact(gray,round(anchor[0])-side//2,round(anchor[1])-side//2,side,1)
        a.perFrame[i].sharpness=sharpness(patch)
    for indices in selected:
        for i in indices:a.perFrame[i].custom=None;a.perFrame[i].birds=[];a.perFrame[i].target=None
        seeds=sorted([s for s in a.customSeeds if s['frame'] in indices and valid_seed(s,a.frames)],key=lambda s:s['frame'])
        for k,seed in enumerate(seeds):
            seed_i=seed['frame'];reference=cache.load_proxy(a.fingerprint,seed_i)
            if reference is None:raise ValueError('无法读取跟踪参考照片。')
            factor=a.frames[seed_i].pixelWidth/reference.shape[1]
            sb=np.array([seed['box'][v]/factor for v in ('x','y','w','h')]);sp=point(seed['anchor'])/factor
            a.perFrame[seed_i].custom=dict(box=seed['box'].copy(),anchor=seed['anchor'].copy(),confidence=1.,source='manual')
            statistics(reference,sb,sp,seed_i)
            mark(seed_i)
            reference_gray=cv2.cvtColor(reference,cv2.COLOR_BGR2GRAY)
            reference_patch=_patch(reference_gray,sb)
            if reference_patch.std()<3:continue
            lower=indices.start if k==0 else (seeds[k-1]['frame']+seed_i)//2+1
            upper=indices.stop if k+1==len(seeds) else (seed_i+seeds[k+1]['frame'])//2+1
            for direction,bound in ((-1,lower-1),(1,upper)):
                previous=reference;box=sb.copy();anchor=sp.copy();cumulative=np.eye(3);missed=0
                for i in range(seed_i+direction,bound,direction):
                    if cancelled():raise Cancelled()
                    current=cache.load_proxy(a.fingerprint,i)
                    if current is None:raise ValueError('无法读取跟踪照片。')
                    mark(i)
                    step=_step(previous,current,box,anchor)
                    if step:
                        transform,newbox,newanchor,quality=step;total=transform@cumulative
                        x,y,w,h=sb
                        sample=total@np.array([[w/32,0,x],[0,h/32,y],[0,0,1.]])
                        gray=cv2.cvtColor(current,cv2.COLOR_BGR2GRAY)
                        patch=cv2.warpAffine(gray,sample[:2],(32,32),flags=cv2.INTER_LINEAR|cv2.WARP_INVERSE_MAP).astype(np.float32)
                        score=_correlation(reference_patch,patch)
                        if score<.3:step=None
                    if step:
                        previous,box,anchor,cumulative=current,newbox,newanchor,total;missed=0
                        statistics(current,box,anchor,i)
                        f=a.frames[i].pixelWidth/current.shape[1]
                        a.perFrame[i].custom=dict(box=dict(zip(('x','y','w','h'),map(float,newbox*f)),score=1.),
                            anchor=dict(x=float(newanchor[0]*f),y=float(newanchor[1]*f)),confidence=min(.95,quality*.8+max(0,score)*.15),source='tracked')
                    else:
                        missed+=1
                        if missed>3:break
    progress(1);a.track=build_track(a);return a


def prepare(frames,fps,cache=None,clips=None,cancelled=lambda:False,progress=lambda p:None):
    cache=cache or ProxyCache();fp=fingerprint(frames,'custom');per=[]
    for i,frame in enumerate(frames):
        if cancelled():raise Cancelled()
        image=F.load_max_side(frame,2560)
        if image is None:raise ValueError('无法读取照片。')
        F.write_jpeg(image,str(cache.proxy_path(fp,i)),95)
        per.append(FrameAnalysis(i,bgLinear=_background_stats(image,None)))
        progress((i+1)/len(frames))
    a=SequenceAnalysis(fp,frames,fps,2560,per,PoseSchema([]),clips=clips or [],groupedDetection=True,subject='custom')
    a.track=build_track(a);return a


def build_custom_track(a):
    n=a.count;positions=np.full((n,2),np.nan);size=np.full(n,np.nan);confidence=np.zeros(n);visible=np.zeros(n,bool)
    for i,p in enumerate(a.perFrame):
        o=p.custom
        if o and all(math.isfinite(v) for v in (*point(o['anchor']),o['box']['w'],o['box']['h'],o['confidence'])):
            positions[i]=point(o['anchor']);size[i]=max(o['box']['w'],o['box']['h']);confidence[i]=o['confidence'];visible[i]=True
        if i in a.manualEye:positions[i]=a.manualEye[i];confidence[i]=1.;visible[i]=True
    has=np.isfinite(positions).all(1)
    # Only bridge short gaps bounded by actual observations. Ends and long occlusions stay lost.
    good=np.flatnonzero(has)
    for left,right in zip(good[:-1],good[1:]):
        if 1<right-left<=3 and left in a.clip_range(right):
            for i in range(left+1,right):
                t=(i-left)/(right-left);positions[i]=(1-t)*positions[left]+t*positions[right]
                size[i]=(1-t)*size[left]+t*size[right];confidence[i]=.3;has[i]=True
    p=np.column_stack([fill_gaps(positions[:,k]) for k in range(2)]) if n else np.empty((0,2))
    p=np.nan_to_num(p)
    s=fill_gaps(size);s=np.where(np.isfinite(s)&(s>0),s,100.)
    return Track(p,p.copy(),s,np.zeros(n),[tuple(positions[i]) if has[i] else None for i in range(n)],visible,has,confidence,False,True,float(np.median(s)) if n else 100.)
