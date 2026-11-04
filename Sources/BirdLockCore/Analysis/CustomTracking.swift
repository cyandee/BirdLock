import Foundation
import CoreGraphics
import Vision

/// No bundled weights: a user-supplied textured region identifies the subject; the interior
/// anchor is refined locally and is never replaced with the centre of a whole-animal box.
public enum CustomTracking {
    public static func valid(_ seed: CustomSeed, frames: [SourceFrame]) -> Bool {
        guard frames.indices.contains(seed.frame) else { return false }
        let f=frames[seed.frame],b=seed.box,p=seed.anchor
        return [b.x,b.y,b.w,b.h,p.x,p.y].allSatisfy(\.isFinite) && min(b.w,b.h)>=4 &&
            b.x>=0 && b.y>=0 && b.x+b.w<=Double(f.pixelWidth)+0.01 && b.y+b.h<=Double(f.pixelHeight)+0.01 && b.rect.contains(CGPoint(x:p.x,y:p.y))
    }

    public static func prepare(frames: [SourceFrame], fps: Double, clips: [BurstClip] = [], cache: ProxyCache = .shared,
                               isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> SequenceAnalysis {
        let fp=Analyzer.fingerprint(frames,aircraftModelIdentity:nil,custom:true)
        var per:[FrameAnalysis]=[]
        for (i,f) in frames.enumerated() {
            if isCancelled() { throw CancellationError() }
            guard let image=ImageLoader.load(f.url,maxPixel:2560) else { throw ModelError.badOutput("无法读取跟踪照片") }
            guard ImageLoader.writeJPEG(image,to:cache.proxyURL(fingerprint:fp,index:i),quality:0.95) else { throw ModelError.badOutput("无法保存跟踪预览") }
            var p=FrameAnalysis(index:i);p.bgLinear=Analyzer.backgroundStats(image,exclude:nil);per.append(p)
            progress(Double(i+1)/Double(max(1,frames.count)))
        }
        var a=SequenceAnalysis(fingerprint:fp,frames:frames,fps:fps,proxyLongSide:2560,perFrame:per,poseSchema:PoseSchema(keypoints:[],inputCropExpand:nil),subject:.custom)
        a.clips=clips;a.groupedDetection=true;a.track=CustomTrackBuilder.build(a);return a
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count==b.count,!a.isEmpty else { return -1 }
        let ma=a.reduce(0,+)/Float(a.count),mb=b.reduce(0,+)/Float(b.count)
        var ab=0.0,aa=0.0,bb=0.0
        for i in a.indices { let x=Double(a[i]-ma),y=Double(b[i]-mb);ab+=x*y;aa+=x*x;bb+=y*y }
        return aa*bb>1e-8 ? ab/sqrt(aa*bb) : -1
    }

    public static func step(previous: CGImage, current: CGImage, box: BoxD, anchor: V2) -> CustomObservation? {
        guard previous.width==current.width,previous.height==current.height else { return nil }
        let w=Double(current.width),h=Double(current.height)
        var candidate=box
        let input=VNDetectedObjectObservation(boundingBox:CGRect(x:box.x/w,y:1-(box.y+box.h)/h,width:box.w/w,height:box.h/h))
        let request=VNTrackObjectRequest(detectedObjectObservation:input);request.trackingLevel = .accurate
        let handler=VNSequenceRequestHandler()
        if (try? handler.perform([request],on:previous)) != nil,
           (try? handler.perform([request],on:current)) != nil,let result=request.results?.first as? VNDetectedObjectObservation,result.confidence>=0.4 {
            let r=result.boundingBox
            candidate=BoxD(x:r.minX*w,y:(1-r.maxY)*h,w:r.width*w,h:r.height*h,score:Double(result.confidence))
        }
        guard min(candidate.w,candidate.h)>=4,candidate.x>=0,candidate.y>=0,candidate.x+candidate.w<=w,candidate.y+candidate.h<=h else { return nil }
        let prediction=V2(candidate.x+(anchor.x-box.x)*candidate.w/box.w,candidate.y+(anchor.y-box.y)*candidate.h/box.h)
        // Keep identical, integer-aligned sampling in both frames. Resizing each patch to a
        // fluctuating Vision rectangle introduces a systematic error in the interior anchor.
        let factor=max(1,Int((max(box.w,box.h)*1.5/128).rounded())),side=Double(128*factor)
        let oa=V2((anchor.x-side/2).rounded(),(anchor.y-side/2).rounded())
        let ob=V2((prediction.x-side/2).rounded(),(prediction.y-side/2).rounded())
        guard let pa=GrayPatch.extractExact(from:previous,x0:Int(oa.x),y0:Int(oa.y),n:128,factor:factor),
              let pb=GrayPatch.extractExact(from:current,x0:Int(ob.x),y0:Int(ob.y),n:128,factor:factor) else { return nil }
        let pc=PhaseCorrelator(size:128)
        guard let match=pc.correlate(pa,pb),match.quality>=18,match.shift.length<38 else { return nil }
        let point=anchor+(ob-oa)+match.shift*Double(factor)
        let offset=point-prediction
        candidate.x+=offset.x;candidate.y+=offset.y
        guard point.x>=0,point.x<w,point.y>=0,point.y<h,candidate.x>=0,candidate.y>=0,candidate.x+candidate.w<=w,candidate.y+candidate.h<=h,
              let old=GrayPatch.extract(from:previous,rect:box.rect,outW:32,outH:32),
              let now=GrayPatch.extract(from:current,rect:candidate.rect,outW:32,outH:32),correlation(old.data,now.data)>=0.3 else { return nil }
        return CustomObservation(box:candidate,anchor:point,confidence:min(0.95,0.65+match.quality/500))
    }

    public static func retrack(_ input: SequenceAnalysis, span: Range<Int>? = nil, cache: ProxyCache = .shared,
                               isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> SequenceAnalysis {
        var a=input
        let ranges=(a.clips ?? []).isEmpty ? [0..<a.count] : a.clips!.map { $0.start..<($0.start+$0.count) }
        let selected=ranges.filter { span==nil || span!.lowerBound==$0.lowerBound }
        let total=max(1,selected.reduce(0) { $0+$1.count });var finished=Set<Int>()
        func mark(_ i: Int) { finished.insert(i);progress(Double(finished.count)/Double(total)) }
        func statistics(_ image: CGImage, _ box: BoxD, _ anchor: V2, _ i: Int) {
            a.perFrame[i].bgLinear=Analyzer.backgroundStats(image,exclude:box.rect)
            let side=Int(clamp(min(box.w,box.h),16,384))
            if let patch=GrayPatch.extractExact(from:image,x0:Int(anchor.x)-side/2,y0:Int(anchor.y)-side/2,n:side,factor:1) {
                a.perFrame[i].sharpness=Sharpness.score(patch)
            }
        }
        if isCancelled() { throw CancellationError() };progress(0)
        for range in selected {
            for i in range { a.perFrame[i].custom=nil;a.perFrame[i].birds=[];a.perFrame[i].target=nil }
            let seeds=(a.customSeeds ?? []).filter { range.contains($0.frame) && valid($0,frames:a.frames) }.sorted { $0.frame<$1.frame }
            for (k,seed) in seeds.enumerated() {
                if isCancelled() { throw CancellationError() }
                guard let reference=cache.loadProxy(fingerprint:a.fingerprint,index:seed.frame) else { throw ModelError.badOutput("无法读取参考照片") }
                let factor=Double(a.frames[seed.frame].pixelWidth)/Double(reference.width)
                let sb=BoxD(x:seed.box.x/factor,y:seed.box.y/factor,w:seed.box.w/factor,h:seed.box.h/factor,score:1)
                let sp=seed.anchor/factor
                a.perFrame[seed.frame].custom=CustomObservation(box:seed.box,anchor:seed.anchor,confidence:1,source:"manual")
                statistics(reference,sb,sp,seed.frame)
                mark(seed.frame)
                let lower=k==0 ? range.lowerBound : (seeds[k-1].frame+seed.frame)/2+1
                let upper=k+1==seeds.count ? range.upperBound : (seed.frame+seeds[k+1].frame)/2+1
                for (direction,bound) in [(-1,lower-1),(1,upper)] {
                    var previous=reference,box=sb,anchor=sp,missed=0,i=seed.frame+direction
                    while i != bound {
                        if isCancelled() { throw CancellationError() }
                        guard let current=cache.loadProxy(fingerprint:a.fingerprint,index:i) else { throw ModelError.badOutput("无法读取跟踪照片") }
                        mark(i)
                        if var result=autoreleasepool(invoking: { step(previous:previous,current:current,box:box,anchor:anchor) }),
                           let original=GrayPatch.extract(from:reference,rect:sb.rect,outW:32,outH:32),
                           let candidate=GrayPatch.extract(from:current,rect:result.box.rect,outW:32,outH:32),correlation(original.data,candidate.data)>=0.25 {
                            previous=current;box=result.box;anchor=result.anchor;missed=0
                            statistics(current,box,anchor,i)
                            let f=Double(a.frames[i].pixelWidth)/Double(current.width)
                            result.box=BoxD(x:box.x*f,y:box.y*f,w:box.w*f,h:box.h*f,score:1);result.anchor=anchor*f
                            a.perFrame[i].custom=result
                        } else { missed+=1;if missed>3 { break } }
                        i+=direction
                    }
                }
            }
        }
        progress(1);a.track=TrackBuilder.build(a);return a
    }
}

public enum CustomTrackBuilder {
    public static func build(_ a: SequenceAnalysis) -> Track {
        let n=a.count
        var points=[V2?](repeating:nil,count:n),sizes=[Double](repeating:.nan,count:n),confidence=[Double](repeating:0,count:n),visible=[Bool](repeating:false,count:n)
        for i in 0..<n {
            if let o=a.perFrame[i].custom,[o.anchor.x,o.anchor.y,o.box.w,o.box.h,o.confidence].allSatisfy(\.isFinite),min(o.box.w,o.box.h)>0 {
                points[i]=o.anchor;sizes[i]=max(o.box.w,o.box.h);confidence[i]=o.confidence;visible[i]=true
            }
            if let manual=a.manualEye[i] { points[i]=manual;confidence[i]=1;visible[i]=true }
        }
        let good=(0..<n).filter { points[$0] != nil }
        for (left,right) in zip(good,good.dropFirst()) where right-left>1 && right-left<=3 && a.clipRange(containing:right).contains(left) {
            for i in (left+1)..<right {
                let t=Double(i-left)/Double(right-left);points[i]=points[left]!*(1-t)+points[right]!*t
                sizes[i]=sizes[left]*(1-t)+sizes[right]*t;confidence[i]=0.3
            }
        }
        let x=Signal.fillGaps(points.map { $0?.x ?? .nan }),y=Signal.fillGaps(points.map { $0?.y ?? .nan }),s=Signal.fillGaps(sizes)
        let frames=(0..<n).map { i -> TrackFrame in
            let p=V2(x[i].isFinite ? x[i] : 0,y[i].isFinite ? y[i] : 0)
            return TrackFrame(eye:p,headCenter:p,headLength:s[i].isFinite && s[i]>0 ? s[i] : 100,angle:0,measuredEye:points[i],eyeVisible:visible[i],hasData:points[i] != nil,confidence:confidence[i])
        }
        return Track(frames:frames,template:nil,reflectDominant:false,facingRight:true,medianHeadLength:Stats.median(frames.map(\.headLength)) ?? 100)
    }
}
