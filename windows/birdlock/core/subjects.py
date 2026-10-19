"""Subject-specific visual preferences; audio and imported photos stay project-wide."""
from dataclasses import dataclass,field

from .settings import (Settings,Composition,CompositionPreset,LookSettings,ExportSettings,FrameSelection,
                       LockPoint,SizeMode,EdgeFill,AspectRatio,PRESETS)


def _aircraft_presets():
    def base(**updates):
        c=Composition(lockPoint=LockPoint.HEAD_CENTER,anchorX=.65,anchorY=.5,framing=20,edgeFill=EdgeFill.BLUR_EXTEND)
        for key,value in updates.items():setattr(c,key,value)
        return c
    return [
        CompositionPreset('aircraft-center','机头居中','机头保持在画面正中',base(anchorX=.5,autoLeadRoom=False)),
        CompositionPreset('aircraft-lead','全机留白','为机身和飞行方向都保留空间',base()),
        CompositionPreset('aircraft-closeup','机头特写','收紧取景，突出机头',base(anchorX=.5,autoLeadRoom=False,framing=7)),
        CompositionPreset('aircraft-wide','宽松全机','展示机身、机翼和周围环境',base(framing=28)),
        CompositionPreset('aircraft-follow','柔和跟随','镜头平缓跟随飞机',base(followSoftness=.45)),
        CompositionPreset('aircraft-natural','自然远近','飞机大小随距离自然变化',base(sizeMode=SizeMode.FIXED_CROP)),
    ]


AIRCRAFT_PRESETS=_aircraft_presets()


def presets(subject):
    return AIRCRAFT_PRESETS if subject=='aircraft' else PRESETS


@dataclass
class SubjectProfile(Settings):
    composition:Composition=field(default_factory=Composition)
    look:LookSettings=field(default_factory=LookSettings)
    export:ExportSettings=field(default_factory=ExportSettings)
    selection:FrameSelection=field(default_factory=FrameSelection)
    presetID:str|None=None

    def untrimmed(self):
        copy=self.copy();copy.selection.trimStart=0;copy.selection.trimEnd=-1
        return copy

    @staticmethod
    def initial_aircraft(bird):
        profile=bird.untrimmed()
        profile.composition=AIRCRAFT_PRESETS[1].composition.copy();profile.presetID='aircraft-lead'
        profile.export.aspect=AspectRatio(16,9,'16:9')
        profile.export.focusMark.enabled=True
        profile.export.focusMark.showEye=False;profile.export.focusMark.showHead=True;profile.export.focusMark.showBody=True
        return profile
