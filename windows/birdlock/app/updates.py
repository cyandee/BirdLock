"""Update UI. Signature checks and installation run in a separate, small Windows process."""
from __future__ import annotations
import json,os,shutil,subprocess,sys,time,uuid,math
from pathlib import Path
from PySide6.QtCore import QProcess,QTimer,Qt,QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QDialog,QVBoxLayout,QLabel,QPushButton,QCheckBox,QProgressBar,QApplication,QMessageBox
from ..core.paths import resource_dir,data_dir,app_dir,FROZEN
from .. import __version__ as VERSION
from ..core.log import log

def preferences():
    try:
        result=json.loads((data_dir()/'updates.json').read_text())
        if not isinstance(result,dict):raise ValueError('Invalid update preferences')
        last=result.get('last_check',0)
        if not isinstance(last,(int,float)) or not math.isfinite(last) or not 0<=last<=time.time()+3600:last=0
        return dict(automatic=result.get('automatic') is True,beta=result.get('beta') is not False,last_check=last)
    except (OSError,ValueError):return {'automatic':False,'beta':True,'last_check':0}

def update_root():
    return Path(os.environ.get('LOCALAPPDATA',Path.home()))/'BirdLock'/'updates'

class UpdateDialog(QDialog):
    def __init__(self,state,parent=None,background=False):
        super().__init__(parent);self.state=state;self.background=background;self.installing=False;self.committing=False;self.session=None;self.child=None
        self.setWindowTitle('BirdLock 更新');self.setWindowModality(Qt.ApplicationModal);self.resize(450,260)
        layout=QVBoxLayout(self);self.message=QLabel('准备检查更新');self.message.setWordWrap(True);layout.addWidget(self.message)
        self.bar=QProgressBar();layout.addWidget(self.bar)
        self.prefs=preferences();self.auto=QCheckBox('自动检查更新（每天一次）');self.auto.setChecked(self.prefs.get('automatic',False));layout.addWidget(self.auto)
        self.beta=QCheckBox('接收测试版更新');self.beta.setChecked(self.prefs.get('beta',True));layout.addWidget(self.beta)
        self.auto.toggled.connect(self.save);self.beta.toggled.connect(self.save);self.beta.toggled.connect(self.check)
        self.install=QPushButton('下载并重启安装');self.install.setEnabled(False);self.install.clicked.connect(self.begin);layout.addWidget(self.install)
        retry=QPushButton('重新检查');retry.clicked.connect(self.check);layout.addWidget(retry)
        download=QPushButton('打开下载页');download.clicked.connect(lambda:QDesktopServices.openUrl(QUrl('https://github.com/cyandee/BirdLock/releases')));layout.addWidget(download)
        self.query=QProcess(self);self.query.finished.connect(self.checked);self.query.errorOccurred.connect(self.query_error)
        self.helper=resource_dir()/'updater'/'BirdLockUpdater.exe'
        self.version=None
        self.timer=QTimer(self);self.timer.setInterval(300);self.timer.timeout.connect(self.poll)
        QTimer.singleShot(0,self.check)
    def save(self,*_):
        self.prefs.update(automatic=self.auto.isChecked(),beta=self.beta.isChecked())
        path=data_dir()/'updates.json';tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(self.prefs));tmp.replace(path)
    def busy(self):
        return self.state.export_running or self.state.phase in ('importing','analyzing')
    def check(self,*_):
        if self.installing or self.query.state()!=QProcess.NotRunning:return
        self.version=None;self.install.setEnabled(False)
        if self.busy():self.message.setText('正在分析或导出，请完成后再检查更新。');return
        try:cfg=json.loads((resource_dir()/'updates'/'config.json').read_text())
        except (OSError,ValueError):cfg={}
        if not cfg.get('enabled') or not self.helper.exists() or os.name!='nt':
            self.message.setText('此测试包尚未启用在线更新，请从下载页安装新版。');return
        self.beta.setEnabled(False)
        self.message.setText('正在检查更新…');self.prefs['last_check']=time.time();self.save()
        self.query.start(str(self.helper),['--check',VERSION]+(['--beta'] if self.beta.isChecked() else []))
    def query_error(self,*_):
        self.beta.setEnabled(True);self.message.setText("无法启动更新器，请手动安装新版。")
        log.error("update helper could not start: %s",self.query.errorString())
    def checked(self,code,*_):
        self.beta.setEnabled(True)
        try:
            if code:raise ValueError(bytes(self.query.readAllStandardError()).decode('utf-8',errors='replace'))
            result=json.loads(bytes(self.query.readAllStandardOutput()));self.version=result['version']
            available=bool(result['available']);self.message.setText(('发现新版 '+self.version+'\n'+result.get('notes','')) if available else '目前没有可用的更新。')
            self.install.setEnabled(available)
            log.info('update check available=%s version=%s channel=%s',available,self.version,result.get('channel'))
            if self.background and available:self.show()
        except (ValueError,KeyError) as e:
            self.version=None;self.install.setEnabled(False)
            self.message.setText('检查更新失败，稍后可重试。\n'+str(e)[:350]);log.warning('update check failed: %s',e)
    def begin(self):
        if self.busy():self.message.setText('正在分析或导出，请稍后更新。');return
        if not FROZEN or not self.version:return
        self.install.setEnabled(False);self.auto.setEnabled(False);self.beta.setEnabled(False)
        self.error_log=None
        try:
            self.session=update_root()/uuid.uuid4().hex;self.session.mkdir(parents=True)
            helper=self.session/'BirdLockUpdater.exe';shutil.copy2(self.helper,helper)
            self.error_log=(self.session/'error.log').open('wb')
            self.child=subprocess.Popen([str(helper),'--install',VERSION,str(app_dir()),str(os.getpid()),self.version]+(['--beta'] if self.beta.isChecked() else []),creationflags=subprocess.CREATE_NO_WINDOW,stdout=subprocess.DEVNULL,stderr=self.error_log)
            self.installing=True;self.timer.start();log.info('update preparing version=%s',self.version)
        except OSError as e:
            if self.error_log:self.error_log.close()
            self.auto.setEnabled(True);self.beta.setEnabled(True)
            self.message.setText('无法启动更新器：'+str(e));log.exception('update launch failed')
    def poll(self):
        try:
            result=json.loads((self.session/'state.json').read_text(encoding='utf-8-sig'));self.message.setText(result['message']);self.bar.setValue(result['percent'])
            if result['status']=='ready':
                self.committing=True;self.state._save_settings_now();QApplication.instance().quit()
            elif result['status']=='error':
                self.installing=False;self.timer.stop();self.error_log.close();self.auto.setEnabled(True);self.beta.setEnabled(True)
                log.error('update failed: %s',result['message'])
        except (OSError,ValueError,KeyError):pass
        if self.child and self.child.poll() is not None and self.installing:
            self.installing=False;self.timer.stop();self.error_log.close();self.auto.setEnabled(True);self.beta.setEnabled(True)
            log.error('update helper exited without completion')
            try:self.message.setText('更新未完成：'+(self.session/'error.log').read_text(encoding='utf-8',errors='replace')[-400:])
            except OSError:self.message.setText('更新器已退出，本次没有完成更新。')
    def reject(self):
        if self.installing and not self.committing:
            (self.session/'cancel').touch();self.message.setText('正在取消更新，请稍候…');return
        if self.query.state()!=QProcess.NotRunning:self.query.kill()
        super().reject()

def startup_health():
    for option in ('--update-health','--update-result'):
        if option not in sys.argv:continue
        i=sys.argv.index(option)
        if i+1>=len(sys.argv):
            del sys.argv[i];continue
        path=Path(sys.argv[i+1]);del sys.argv[i:i+2]
        session=path.parent if option=='--update-health' else path
        try:
            valid=(os.name=='nt' and len(session.name)==32 and uuid.UUID(hex=session.name).hex==session.name
                   and session.parent.resolve()==update_root().resolve() and session.is_dir() and not session.is_symlink())
            if not valid:continue
            if option=='--update-health' and path.name=='health':
                path.write_text(VERSION);log.info('updated app startup health version=%s',VERSION)
            elif option=='--update-result':
                result=json.loads((session/'state.json').read_text(encoding='utf-8-sig'))
                if result.get('status')=='error':
                    message=str(result.get('message','更新未完成'))[:500]
                    log.error('previous update restored: %s',message)
                    QTimer.singleShot(0,lambda text=message:QMessageBox.warning(None,'BirdLock 更新未完成','已重新打开原版本。\n'+text))
        except (OSError,ValueError):log.exception('update startup result could not be recorded')
