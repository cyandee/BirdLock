"""One-time cumulative notes, including migration from accepted 1.5 settings."""
import json,os
from pathlib import Path

def version(value):
    try:
        parts=value.split('.')
        return tuple(int(x) for x in parts) if len(parts)==3 else None
    except (AttributeError,ValueError):return None

class ReleaseNotice:
    def __init__(self,root,current):
        self.path=Path(root)/'release-notice.json';self.current=current
        try:self.state=json.loads(self.path.read_text(encoding='utf-8'))
        except (OSError,ValueError):self.state={}
        if not isinstance(self.state,dict):self.state={}
        try:settings=json.loads((Path(root)/'settings.json').read_text(encoding='utf-8'));self.legacy=bool(settings.get('agreementAccepted'))
        except (OSError,ValueError,AttributeError):self.legacy=False
    def save(self):
        self.path.parent.mkdir(parents=True,exist_ok=True);tmp=self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(self.state),encoding='utf-8');os.replace(tmp,self.path)
    def start(self):
        current=version(self.current)
        if current is None:return False
        previous=self.state.get('lastStartedVersion');old=version(previous)
        newer=old<current if old is not None else previous is None and self.legacy
        if newer and self.state.get('notesSeenVersion')!=self.current:self.state['pendingNotesVersion']=self.current
        self.state['lastStartedVersion']=self.current;self.save()
        return self.state.get('pendingNotesVersion')==self.current and self.state.get('notesSeenVersion')!=self.current
    def acknowledge(self):
        self.state['notesSeenVersion']=self.current;self.state.pop('pendingNotesVersion',None);self.save()
