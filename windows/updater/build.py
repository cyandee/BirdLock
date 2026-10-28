"""Compile the small updater with Windows' framework compiler; no PowerShell policy change."""
from pathlib import Path
import argparse,os,subprocess

def build(config=None,output=None):
    source=Path(__file__).resolve().parent
    config=Path(config or source.parent.parent/'SharedResources/Updates/config.json').resolve()
    output=Path(output or source/'dist/BirdLockUpdater.exe').resolve()
    compiler=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if not compiler.is_file():raise RuntimeError('.NET Framework 4.x compiler is required')
    output.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run([str(compiler),'/nologo','/codepage:65001','/optimize+','/target:exe','/platform:x64',f'/out:{output}',f'/resource:{config},UpdateConfig',
                    '/reference:System.Web.Extensions.dll','/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll',str(source/'Updater.cs'),str(source/'Program.cs')],check=True)
    if output.stat().st_size>3*1024*1024:raise RuntimeError('Updater exceeds the 3 MB target')
    return output

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--config',type=Path);p.add_argument('--output',type=Path)
    a=p.parse_args();print(build(a.config,a.output))
