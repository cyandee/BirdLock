"""User-requested diagnostic bundle; contains logs and system details, never photos or settings."""
import json
import logging
import os
from pathlib import Path
import platform
import re
import sys
import zipfile
from datetime import datetime

from .paths import data_dir


def redact(text):
    homes = {str(Path.home()), str(Path.home()).replace('\\', '/')}
    for home in sorted(homes, key=len, reverse=True):
        text = text.replace(home, '<用户目录>')
    text = re.sub(r'(?i)[A-Z]:[\\/][^\r\n\"\']+', '<本地路径>', text)
    text = re.sub(r'(?i)(token|password|secret|authorization)([=: ]+)[^\s,;]+', r'\1\2<已隐藏>', text)
    return text


def export_bundle(destination):
    from .. import __version__
    from .gpu import list_adapters
    for handler in logging.getLogger('birdlock').handlers:
        handler.flush()
    root = data_dir()
    output = Path(destination).resolve()
    files = []
    for pattern in ('birdlock.log*', 'crash.log*', 'app.log*'):
        files.extend(p for p in root.glob(pattern) if p.is_file() and p.resolve() != output)
    info = dict(version=__version__, system=platform.platform(), python=platform.python_version(),
                machine=platform.machine(), cpu_count=os.cpu_count(), created=datetime.now().isoformat(),
                previous_exit_unexpected=(root/'previous-exit-unexpected').exists())
    info['adapters'] = [dict(name=a.name, vendor=a.vendor, memory_mb=a.dedicated_mb) for a in list_adapters()]
    # Avoid overwriting a valid bundle with a partially written ZIP.
    temporary = output.with_name(output.name+'.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as bundle:
            bundle.writestr('system.json', json.dumps(info, ensure_ascii=False, indent=2))
            for path in sorted(set(files)):
                with path.open('rb') as stream:
                    stream.seek(max(0, path.stat().st_size-(4<<20)))
                    content = stream.read().decode('utf-8', 'replace')
                bundle.writestr(path.name, redact(content))
            # Only three recent update sessions and explicit log/status files. No archives or keys.
            update_root=Path(os.environ.get('LOCALAPPDATA',Path.home()))/'BirdLock'/'updates'
            if update_root.is_dir() and not update_root.is_symlink():
                sessions=[p for p in update_root.iterdir() if re.fullmatch('[0-9a-f]{32}',p.name) and p.is_dir() and not p.is_symlink()]
                for session in sorted(sessions,key=lambda p:p.stat().st_mtime,reverse=True)[:3]:
                    for name in ('state.json','error.log','events.log'):
                        path=session/name
                        if path.is_file() and not path.is_symlink():
                            with path.open('rb') as stream:
                                stream.seek(max(0,path.stat().st_size-262144));text=stream.read().decode('utf-8','replace')
                            bundle.writestr('updates/'+session.name+'/'+name,redact(text))
            bundle.writestr('说明.txt', '包括运行/崩溃日志和系统信息，默认隐藏用户目录；不包含原照片、音频、二维码或设置文件。发送前仍可自行检查。\n')
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return output
