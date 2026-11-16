"""Reveal originals without shell expansion or changes to user files."""
from pathlib import Path
import ctypes
import os
import subprocess

from PySide6.QtCore import QUrl
from PySide6.QtGui import QDesktopServices


def original_path(frame):
    import json
    path = Path(frame.path)
    # Imported video frames are disposable cache files, not original photos.
    recipe = path.parent/'video-recipe.json'
    if recipe.is_file():
        try:
            return Path(json.loads(recipe.read_text(encoding='utf-8'))['sourcePath'])
        except (OSError, ValueError, KeyError, TypeError):
            return None
    return path


def select_in_explorer(paths):
    files = list(dict.fromkeys(p.absolute() for p in paths if p is not None and p.is_file()))
    if not files:
        return False
    first = files[0]
    if os.name == 'nt':
        # Explorer can select several children of a single folder. For
        # mixed directories select the available files alongside the first.
        selected = [p for p in files if p.parent == first.parent]
        if 1 < len(selected) <= 1024:
            import logging
            try:
                shell, ole = ctypes.windll.shell32, ctypes.windll.ole32
                ptr = ctypes.c_void_p
                parse = shell.SHParseDisplayName
                parse.argtypes = [ctypes.c_wchar_p,ptr,ctypes.POINTER(ptr),ctypes.c_ulong,ptr]
                last = shell.ILFindLastID
                last.argtypes = [ptr];last.restype = ptr
                open_select = shell.SHOpenFolderAndSelectItems
                open_select.argtypes = [ptr,ctypes.c_uint,ctypes.POINTER(ptr),ctypes.c_ulong]
                ole.CoTaskMemFree.argtypes = [ptr]
                allocated=[]
                def pidl(p):
                    dest=ptr()
                    code=parse(str(p),None,ctypes.byref(dest),0,None)
                    if dest:allocated.append(dest)
                    if code<0 or not dest:raise OSError('Explorer could not resolve the file')
                    return dest
                try:
                    base=pidl(first.parent)
                    children=[last(pidl(p)) for p in selected]
                    if open_select(base,len(children),(ptr*len(children))(*children),0)>=0:
                        return True
                finally:
                    for item in allocated:ole.CoTaskMemFree(item)
            except OSError:
                logging.getLogger(__name__).info('Explorer batch selection unavailable; using one original')
        try:
            subprocess.Popen(['explorer.exe','/select,',str(first)])
            return True
        except OSError:
            pass
    return QDesktopServices.openUrl(QUrl.fromLocalFile(str(first.parent)))
