"""Camera-motion stabilization, independent of subject detection.

KLT/RANSAC image motion, synchronized IMU rotations, symmetric path smoothing and
adaptive safe cropping. All matrices map original, top-left pixels to output.
"""
from __future__ import annotations

from dataclasses import replace
import itertools
import json
import math
from pathlib import Path

import cv2
import numpy as np

from .frames import load_image
from .util import gaussian, running_max, running_median

SCHEMA = 2


def apply(h, point):
    p = h @ np.array([*point, 1.], dtype=np.float64)
    return p[:2] / p[2]


def similarity(dx=0., dy=0., angle=0., log_scale=0.):
    c, s = math.cos(angle)*math.exp(log_scale), math.sin(angle)*math.exp(log_scale)
    return np.array([[c,-s,dx],[s,c,dy],[0,0,1]], np.float64)


def cache_file(frames):
    if not frames: return None
    folder = Path(frames[0].path).parent
    return folder/'motion.json' if (folder/'video-source.json').is_file() and all(Path(f.path).parent == folder for f in frames) else None


def image_pair(previous, current):
    """Pyramidal LK with forward/backward rejection, then a robust similarity fit."""
    corners = cv2.goodFeaturesToTrack(previous, 500, .008, 12, blockSize=5)
    matrix, confidence = None, 0.
    if corners is not None and len(corners) >= 8:
        target, status, _ = cv2.calcOpticalFlowPyrLK(previous, current, corners, None, winSize=(31,31), maxLevel=4)
        back, status2, _ = cv2.calcOpticalFlowPyrLK(current, previous, target, None, winSize=(31,31), maxLevel=4)
        good = (status.ravel() != 0) & (status2.ravel() != 0) & (np.linalg.norm(back-corners, axis=2).ravel() < 1.5)
        if good.sum() >= 8:
            a, b = corners[good].reshape(-1,2), target[good].reshape(-1,2)
            fit, inliers = cv2.estimateAffinePartial2D(a,b,method=cv2.RANSAC,ransacReprojThreshold=2,maxIters=2000,confidence=.995)
            if fit is not None and inliers is not None:
                confidence = float(inliers.mean()) * min(1., len(a)/40)
                if confidence >= .25: matrix = np.vstack([fit,[0,0,1.]])
    if matrix is None:
        # Dense phase registration is a bounded fallback for few but coherent features.
        shift, response = cv2.phaseCorrelate(previous.astype(np.float32), current.astype(np.float32))
        if response >= .15:
            matrix, confidence = similarity(*shift), min(.6, float(response))
    if matrix is None: return np.eye(3), 0.
    scale = math.hypot(matrix[0,0], matrix[1,0])
    displacement = np.linalg.norm(apply(matrix, np.array(previous.shape[::-1])/2)-np.array(previous.shape[::-1])/2)
    if not np.isfinite(matrix).all() or not .94 < scale < 1.06 or abs(math.atan2(matrix[1,0],matrix[0,0])) > .25 or displacement > max(previous.shape)*.25:
        return np.eye(3), 0.
    return matrix, confidence


def physical_intrinsics(metadata_frames, width, height):
    """A pinhole estimate from constant recorded mm; it is not a distortion calibration."""
    if not metadata_frames or width<=0 or height<=0:return None
    values=[]
    for frame in metadata_frames:
        row=[frame.get('Default',{}).get('SensorWidth'),frame.get('Default',{}).get('SensorHeight'),frame.get('Lens',{}).get('FocalLength')]
        if not all(isinstance(v,(float,int)) and math.isfinite(v) and v>0 for v in row):return None
        values.append(row)
    values=np.asarray(values,float);base=values.mean(axis=0)
    if np.any(np.ptp(values,axis=0)/base>1e-4):return None
    sw,sh,focal=base
    if abs((sw/sh)/(width/height)-1)>.002:return None
    return [float(width*focal/sw),float(height*focal/sh),width/2,height/2]


def prepare(frames, video, start, fps, *, profile=None, force=False, progress=lambda p:None, cancelled=lambda:False):
    """Measure once in a worker; settings changes only recompute the cheap camera path."""
    path = cache_file(frames)
    if path is None: return None
    if path.is_file() and not force:
        data = load(frames)
        if data is not None:return data
    from .video_import import VideoImportCancelled
    n = len(frames); w,h = frames[0].pixelWidth,frames[0].pixelHeight
    steps, previous = [[0.,0.,0.,0.,1.]], None
    for i, frame in enumerate(frames):
        if cancelled(): raise VideoImportCancelled()
        image = load_image(frame, scale=.25 if max(w,h)>1920 else .5 if max(w,h)>960 else 1, gray=True)
        if image is None: raise ValueError('无法读取视频帧进行防抖分析')
        factor = min(1., 960/max(image.shape))
        if factor < 1: image = cv2.resize(image,None,fx=factor,fy=factor,interpolation=cv2.INTER_AREA)
        if previous is not None:
            matrix, quality = image_pair(previous, image)
            s = image.shape[1]/w
            steps.append([float(matrix[0,2]/s),float(matrix[1,2]/s),math.atan2(matrix[1,0],matrix[0,0]),math.log(math.hypot(matrix[0,0],matrix[1,0])),quality])
        previous = image
        progress(.8*(i+1)/n)
    from .camera_metadata import CameraMetadata
    from .lens_catalog import detect
    try:metadata = detect(video,width=w,height=h,fps=fps).metadata
    except (OSError,ValueError):metadata = CameraMetadata()
    focal = metadata.focalLength
    if not focal:
        import re
        match = re.search(r'(\d+(?:\.\d+)?)\s*mm',metadata.lensModel or '',re.I)
        focal = float(match[1]) if match else None
    sensor = 23.5 if any(k in (metadata.cameraModel or '').upper() for k in ('6700','6600','6500','6400','ZV-E10','FX30')) else 36.
    fx = w*focal/sensor if focal and focal>0 else .9*w
    intrinsics=[fx,fx,w/2,h/2]
    if profile:
        from .lens_profile import LensProfile
        lens=LensProfile.load(profile);k=lens.matrix.copy();k[0]*=w/lens.width;k[1]*=h/lens.height
        intrinsics=[float(k[0,0]),float(k[1,1]),float(k[0,2]),float(k[1,2])]
    gyro, warning = [], ''
    intrinsics_source='lens-profile' if profile else 'camera-estimate'
    try:
        from .telemetry_io import read_telemetry
        report=read_telemetry(video,cancelled=cancelled)
        gyro=[[s['t'],*s['gyro']] for s in report['samples']]
        if not profile:
            physical=physical_intrinsics(report.get('rawMetadataFrames',[]),w,h)
            if physical is not None:intrinsics=physical;intrinsics_source='physical-sensor-estimate'
        warning='；'.join(report.get('warnings',[]))
    except Exception as error:
        if cancelled(): raise VideoImportCancelled()
        warning=str(error)
    data=dict(schema=SCHEMA,width=w,height=h,fps=float(fps),start=float(start),intrinsics=intrinsics,intrinsicsSource=intrinsics_source,steps=steps,gyro=gyro,telemetryWarning=warning)
    save_record(path,data)
    progress(1.)
    return data


def save_record(path, data):
    temporary=Path(path).with_suffix('.motion.part')
    temporary.write_text(json.dumps(data,separators=(',',':')),encoding='utf-8')
    temporary.replace(path)


def load(frames):
    path=cache_file(frames)
    if path is None or not path.is_file():return None
    try:
        data=json.loads(path.read_text(encoding='utf-8'))
        if data.get('schema')!=SCHEMA or len(data['steps'])!=len(frames):return None
        if not (math.isfinite(data['fps']) and 0<data['fps']<=240 and math.isfinite(data['start']) and data['start']>=0):return None
        k=np.asarray(data['intrinsics'],float)
        if k.shape!=(4,) or not np.isfinite(k).all() or min(k[:2])<=0:return None
        values=np.asarray(data['steps'],float)
        if values.shape!=(len(frames),5) or not np.isfinite(values).all():return None
        if data['width'] != frames[0].pixelWidth or data['height'] != frames[0].pixelHeight:return None
        imu=np.asarray(data.get('gyro',[]),float)
        if imu.size and (imu.ndim!=2 or imu.shape[1]!=4 or not np.isfinite(imu).all() or np.any(np.diff(imu[:,0])<=0)):return None
        return data
    except (OSError,ValueError,KeyError,TypeError):return None


def import_gyro(frames, source, *, cancelled=lambda:False):
    data=load(frames)
    if data is None:raise ValueError('请先导入视频并完成防抖分析')
    from .telemetry_io import read_telemetry
    report=read_telemetry(source,cancelled=cancelled)
    if len(report['samples'])<10:raise ValueError('此文件没有足够的陀螺仪采样，请选择相机原片、GCSV 或含原始数据的 Gyroflow 工程')
    data['gyro']=[[s['t'],*s['gyro']] for s in report['samples']]
    data['gyroSource']=Path(source).name
    data['telemetryWarning']=''
    sync=synchronize(data)
    save_record(cache_file(frames),data)
    return sync


def optical_angular_velocity(data):
    steps=np.asarray(data['steps'],float);fps=data['fps'];fx,fy,cx,cy=data['intrinsics']
    vectors=[]
    for dx,dy,angle,scale,quality in steps[1:]:
        delta=apply(similarity(dx,dy,angle,scale),[cx,cy])-[cx,cy]
        vectors.append([delta[1]/fy*fps,-delta[0]/fx*fps,-angle*fps])
    return np.asarray(vectors)


def synchronize(data, initial=0., search=.5):
    """Correlate measured camera angular velocities with IMU; return positive gyro time offset."""
    imu=np.asarray(data.get('gyro',[]),float);opt=optical_angular_velocity(data)
    fallback=dict(offset=float(initial),score=0.,valid=False,axes=[1,0,2],signs=[-1,-1,-1])
    if len(imu)<10 or len(opt)<12:return fallback
    times=data['start']+(np.arange(len(opt))+.5)/data['fps'];quality=np.asarray(data['steps'])[1:,4]
    valid=quality>=.3
    if valid.sum()<12:return fallback
    opt=opt-np.stack([gaussian(opt[:,j],max(1,data['fps']*.25)) for j in range(3)],axis=1)
    weights=np.std(opt[valid],axis=0);active=weights>max(1e-5,weights.max()*.1)
    if not active.any():return fallback
    optnorm=np.sqrt(np.sum(opt[valid]**2,axis=0))+1e-12
    best=(-2.,initial,None,None)
    permutations=list(itertools.permutations(range(3)))
    def evaluate(offset):
        at=times+offset
        mask=valid & (at>=imu[0,0]) & (at<=imu[-1,0])
        if mask.sum()<max(12,valid.sum()*.8):return None
        g=np.stack([np.interp(at,imu[:,0],imu[:,j+1]) for j in range(3)],axis=1)
        g-=np.stack([gaussian(g[:,j],max(1,data['fps']*.25)) for j in range(3)],axis=1)
        denom=np.linalg.norm(opt[mask],axis=0)[:,None]*np.linalg.norm(g[mask],axis=0)[None,:]+1e-16
        corr=(opt[mask].T@g[mask])/denom
        winner=None
        for axes in permutations:
            signs=np.where([corr[j,axes[j]]>=0 for j in range(3)],1.,-1.)
            # Rigid IMU-to-camera orientation must preserve handedness.
            if np.linalg.det(np.eye(3)[list(axes)]*signs[:,None])<0:signs[np.argmin(weights)]=-signs[np.argmin(weights)]
            score=float(sum(weights[j]*corr[j,axes[j]]*signs[j] for j in range(3) if active[j])/sum(weights[active]))
            if winner is None or score>winner[0]:winner=(score,offset,list(axes),signs.tolist())
        return winner
    coarse=[]
    for offset in np.arange(initial-search,initial+search+.0025,.005):
        result=evaluate(float(offset))
        if result:coarse.append(result)
        if result and result[0]>best[0]:best=result
    for offset in np.arange(best[1]-.005,best[1]+.00501,.0005):
        result=evaluate(float(offset))
        if result and result[0]>best[0]:best=result
    runner=max((item[0] for item in coarse if abs(item[1]-best[1])>.07),default=-1.)
    valid=best[0]>=.6 and best[0]-runner>=.03 and abs(best[1]-initial)<search-.005
    return dict(offset=best[1],score=max(0.,best[0]),valid=valid,axes=best[2] or [1,0,2],signs=best[3] or [-1,-1,-1])


def rotation(vector):
    angle=np.linalg.norm(vector)
    if angle<1e-12:return np.eye(3)
    x,y,z=vector/angle;k=np.array([[0,-z,y],[z,0,-x],[-y,x,0]])
    return np.eye(3)+math.sin(angle)*k+(1-math.cos(angle))*(k@k)


def quaternion_multiply(a,b):
    w,x,y,z=a;v,i,j,k=b
    return np.array([w*v-x*i-y*j-z*k,w*i+x*v+y*k-z*j,w*j-x*k+y*v+z*i,w*k+x*j-y*i+z*v])


def quaternion_step(vector):
    angle=np.linalg.norm(vector)
    if angle<1e-12:return np.array([1.,0.,0.,0.])
    return np.r_[math.cos(angle/2),vector/angle*math.sin(angle/2)]


def quaternion_matrix(q):
    w,x,y,z=q/np.linalg.norm(q)
    return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
                     [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
                     [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])


def corrections(data, settings):
    steps=np.asarray(data['steps'],float);n=len(steps);fps=data['fps']
    paths=[np.eye(3)]
    for dx,dy,angle,scale,quality in steps[1:]:paths.append(similarity(dx,dy,angle,scale)@paths[-1])
    paths=np.asarray(paths)
    coords=np.array([[m[0,2],m[1,2],math.atan2(m[1,0],m[0,0]),math.log(math.hypot(m[0,0],m[1,0]))] for m in paths])
    coords[:,2]=np.unwrap(coords[:,2])
    sigma=max(.5,min(600.,settings.smoothness*fps))
    target=np.stack([gaussian(coords[:,j],sigma) for j in range(4)],axis=1)
    visual=np.asarray([similarity(*target[i])@np.linalg.inv(paths[i]) for i in range(n)])
    result=visual;method='图像防抖';sync=synchronize(data) if data.get('gyro') and settings.autoSync else dict(offset=0.,score=0.,valid=False,axes=[1,0,2],signs=[-1,-1,-1])
    if not sync['valid']:
        sync.update(offset=0.,axes=[1,0,2],signs=[-1,-1,-1])
    if settings.method!='visual' and len(data.get('gyro',[]))>=10:
        imu=np.asarray(data['gyro'],float);axes=sync['axes'];signs=np.asarray(sync['signs'])
        rates=imu[:,1:][:,axes]*signs
        deltas=np.diff(imu[:,0]);max_gap=max(.1,5*float(np.median(deltas)))
        quaternions=[np.array([1.,0.,0.,0.])]
        for i in range(1,len(imu)):
            dt=imu[i,0]-imu[i-1,0]
            q=quaternion_multiply(quaternions[-1],quaternion_step((rates[i]+rates[i-1])*.5*dt)) if dt<=max_gap else quaternions[-1].copy()
            if np.dot(q,quaternions[-1])<0:q=-q
            quaternions.append(q/np.linalg.norm(q))
        quaternions=np.asarray(quaternions)
        times=data['start']+np.arange(n)/fps+sync['offset']+settings.gyroOffset
        poses=np.stack([np.interp(times,imu[:,0],quaternions[:,j]) for j in range(4)],axis=1)
        poses/=np.linalg.norm(poses,axis=1)[:,None]
        smooth=np.stack([gaussian(poses[:,j],sigma) for j in range(4)],axis=1)
        smooth/=np.maximum(np.linalg.norm(smooth,axis=1)[:,None],1e-12)
        fx,fy,cx,cy=data['intrinsics'];k=np.array([[fx,0,cx],[0,fy,cy],[0,0,1.]])
        gyro=np.asarray([k@quaternion_matrix(smooth[i]).T@quaternion_matrix(poses[i])@np.linalg.inv(k) for i in range(n)])
        coverage=(times>=imu[0,0]-1/fps)&(times<=imu[-1,0]+1/fps)
        margin=math.ceil(3*sigma)/fps
        for gap in np.flatnonzero(deltas>max_gap):
            coverage &= (times<imu[gap,0]-margin) | (times>imu[gap+1,0]+margin)
        gyro[~coverage]=visual[~coverage]
        result=gyro;method='陀螺仪防抖'
        if settings.method=='auto':
            # Image residuals also compensate image shift left by IBIS or imperfect lens geometry.
            center=np.array([cx,cy]);residual=np.array([apply(visual[i]@np.linalg.inv(gyro[i]),center)-center for i in range(n)])
            residual=np.stack([gaussian(residual[:,j],max(.5,fps*.04)) for j in range(2)],axis=1)
            result=np.asarray([similarity(*(residual[i]*min(1.,steps[i,4])) )@gyro[i] for i in range(n)])
            method='陀螺仪＋图像融合'
    identity=np.eye(3)
    result=identity+(result-identity)*max(0,min(1,settings.strength))
    result/=result[:,2:3,2:3]
    return result,dict(method=method,sync=sync,gyroSamples=len(data.get('gyro',[])),measuredFrames=int((steps[:,4]>=.3).sum()))


def compose_plan(analysis, track, composition, export, used, settings):
    data=load(analysis.frames)
    if data is None or not settings.enabled:return None,None
    from .planner import CompositionPlan,FrameXform,plan as make_plan
    matrices,status=corrections(data,settings);w,h=data['width'],data['height'];ow,oh=export.output_size
    from .settings import SizeMode
    lock_size=settings.framing=='subject' and composition.sizeMode==SizeMode.LOCK_SIZE and track.has_data.any()
    camera_scale=np.exp(np.clip(np.cumsum([step[3] if i and step[4]>=.3 else 0 for i,step in enumerate(data['steps'])]),-4,4))
    if lock_size:
        for i,m in enumerate(matrices):
            p=track.head_center[i];center=apply(m,p)
            x,y=apply(m,p+[1,0])-center,apply(m,p+[0,1])-center
            scale=camera_scale[i]*math.sqrt(abs(x[0]*y[1]-x[1]*y[0]))
            if math.isfinite(scale) and scale>.01:
                matrices[i]=similarity(*center)@similarity(log_scale=-math.log(scale))@similarity(*(-center))@m
    head_center=np.array([apply(m,p) for m,p in zip(matrices,track.head_center)])
    endpoints=track.head_center+np.stack([np.cos(track.angle),np.sin(track.angle)],axis=1)*track.head_length[:,None]
    direction=np.array([apply(m,p) for m,p in zip(matrices,endpoints)])-head_center
    lengths=np.linalg.norm(direction,axis=1)
    if lock_size:lengths=stable_head_sizes(track.head_length/camera_scale,composition.sizeSmoothing)
    angles=np.arctan2(direction[:,1],direction[:,0])
    changes=angles-track.angle
    transformed=replace(track,eye=np.array([apply(m,p) for m,p in zip(matrices,track.eye)]),
        head_center=head_center,head_length=lengths,angle=track.angle+np.arctan2(np.sin(changes),np.cos(changes)),
        median_head_length=float(np.median(lengths)))
    if settings.framing=='camera' or not track.has_data.any():
        z=max(ow/w,oh/h)
        base=CompositionPlan([FrameXform(np.array([w/2,h/2]),np.array([ow/2,oh/2]),z,0,True) for _ in matrices],float(ow),float(oh),z,0)
    else:base=make_plan(transformed,analysis.frames,composition,float(ow),float(oh),used or None)
    anchors={id(x):apply(np.linalg.inv(matrices[i]),x.a) for i,x in enumerate(base.xforms)} if settings.framing=='subject' and track.has_data.any() else {}
    def fits(xf,matrix,zoom):
        test=replace(xf,z=xf.z*zoom,prewarp=matrix)
        if id(xf) in anchors:test.a=apply(matrix,anchors[id(xf)])
        try:quad=np.asarray(test.source_quad(ow,oh))
        except (ValueError,np.linalg.LinAlgError):return False
        return bool(np.isfinite(quad).all() and (quad>=-.01).all() and (quad[:,0]<=w+.01).all() and (quad[:,1]<=h+.01).all())
    zooms=[];limited=0
    for i,xf in enumerate(base.xforms):
        matrix=matrices[i];zoom=1.
        if settings.autoZoom:
            limit=max(1.,min(8.,settings.maxZoom))
            for _ in range(20):
                if fits(xf,matrix,limit):break
                matrix=np.eye(3)+(matrix-np.eye(3))*.7;limited+=1
            if not fits(xf,matrix,limit) and fits(xf,np.eye(3),limit):matrix=np.eye(3)
            lo,hi=1.,limit
            for _ in range(16):
                mid=(lo+hi)/2
                if fits(xf,matrix,mid):hi=mid
                else:lo=mid
            zoom=hi
        if id(xf) in anchors:base.xforms[i]=replace(xf,a=apply(matrix,anchors[id(xf)]))
        matrices[i]=matrix;zooms.append(zoom)
    if settings.autoZoom:
        eased=gaussian(running_max(np.asarray(zooms),max(1,int(data['fps']*.15))),max(.5,data['fps']*.1))
        zooms=np.maximum(zooms,eased)
        if settings.fixedZoom or lock_size:zooms=np.full(len(zooms),max(zooms[i] for i in (used or range(len(zooms)))))
    xforms=[replace(xf,z=xf.z*zooms[i],prewarp=matrices[i]) for i,xf in enumerate(base.xforms)]
    status.update(maxZoom=float(max(zooms)),limited=limited>0)
    return replace(base,xforms=xforms,max_upscale=max(x.z for x in xforms)),status


def stable_head_sizes(values,smoothing):
    logs=np.log(np.maximum(values,1e-3));center=float(np.median(logs))
    filtered=gaussian(running_median(logs,3),max(2,smoothing));delta=filtered-center
    return np.exp(center+np.sign(delta)*np.maximum(0,np.abs(delta)-math.log(1.10)))
