from pathlib import Path
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import (QApplication,QCheckBox,QDialog,QDialogButtonBox,QFileDialog,QFormLayout,QLabel,QMessageBox,QPushButton,QSpinBox,QVBoxLayout)
from ..core import workspace, cache_policy

class ProjectActions:
    def can_leave_project(self):
        st=self.state
        if st.export_running or st.phase in ('importing','analyzing'):
            QMessageBox.information(self,'任务进行中','请先完成或取消当前导入、分析或导出。');return False
        if not st.project_dirty or st.analysis is None:return True
        result=QMessageBox.question(self,'保存工程？','当前编辑尚未保存到工程文件。是否先保存？',QMessageBox.Save|QMessageBox.Discard|QMessageBox.Cancel,QMessageBox.Save)
        if result==QMessageBox.Cancel:return False
        return self.save_project_dialog() if result==QMessageBox.Save else True

    def save_project_dialog(self,save_as=False):
        st=self.state
        if st.analysis is None:return False
        path=st.project_path if not save_as else ''
        parent=QApplication.activeModalWidget() or self
        if not path:
            from ..core.video_source import original_path
            source=Path(original_path(st.frames) or st.frames[0].path)
            path,_=QFileDialog.getSaveFileName(parent,'保存BirdLock工程',str(source.with_name(source.stem+'_工程.birdlock')),'BirdLock工程 (*.birdlock)')
            if not path:return False
            if Path(path).suffix.lower()!='.birdlock':path+='.birdlock'
        try:st.save_project(path);return True
        except Exception as error:QMessageBox.warning(parent,'工程未保存',str(error));return False

    def open_project_dialog(self,path=None):
        if not path:path,_=QFileDialog.getOpenFileName(self,'打开BirdLock工程','','BirdLock工程 (*.birdlock)')
        if not path:return
        try:
            try:document=workspace.read(path)
            except workspace.MissingMedia as error:
                QMessageBox.information(self,'重新定位素材',str(error)+'\n请选择原片所在的文件夹。')
                folder=QFileDialog.getExistingDirectory(self,'选择素材所在文件夹')
                if not folder:return
                document=workspace.read(path,folder)
            if not self.can_leave_project():return
            self.state.open_project(path,document)
        except Exception as error:QMessageBox.warning(self,'无法打开工程',str(error))

    def close_project_dialog(self):
        if self.can_leave_project():self.state.close_project();self.state.trim_cache()

    def project_ui_changed(self,topic):
        st=self.state
        name=Path(st.project_path).name if st.project_path else '未命名工程' if st.analysis else ''
        self.setWindowTitle('BirdLock'+(' · '+name if name else '')+(' *' if st.project_dirty and st.analysis else ''))
        if topic=='export' and not st.export_running and st.export_progress>=1 and st.last_export_kind=='video' and st.ask_cleanup_after_export:
            if getattr(self,'_cleanup_prompted',-1)!=st.cleanup_export_token and st.analysis and any((Path(f.path).parent/'video-recipe.json').is_file() for f in st.frames):
                self._cleanup_prompted=st.cleanup_export_token
                QTimer.singleShot(0,self.offer_export_cleanup)

    def offer_export_cleanup(self):
        st=self.state
        if st._closing or st.export_running or not st.analysis:return
        parent=QApplication.activeModalWidget() or self
        box=QMessageBox(parent);box.setWindowTitle('视频已导出')
        box.setText('是否保存工程并清理本次视频的过程文件？')
        box.setInformativeText('清理后将关闭当前工作，保留原片和导出视频。下次打开工程时按需重新生成视频帧，沿用保存的识别结果与编辑。')
        keep=box.addButton('保留过程文件',QMessageBox.RejectRole)
        clean=box.addButton('保存工程并清理',QMessageBox.AcceptRole);box.setDefaultButton(keep)
        box.exec()
        if box.clickedButton()!=clean or not self.save_project_dialog():return
        try:
            report=st.clean_current_video()
            QMessageBox.information(parent,'过程文件已清理',f'已释放 {report["removed"]/(1<<30):.2f} GB。工程、原片和导出视频保留。'+('部分文件正被占用，可稍后重试。' if report['failures'] else ''))
        except Exception as error:QMessageBox.warning(parent,'未能完成清理',str(error))

    def cache_settings_dialog(self):
        st=self.state;d=QDialog(self);d.setWindowTitle('缓存管理');d.setMinimumWidth(450)
        v=QVBoxLayout(d);usage=QLabel(f'当前缓存占用 {cache_policy.total_size(st.cache.root)/(1<<30):.2f} GB');v.addWidget(usage)
        form=QFormLayout();limit=QSpinBox();limit.setRange(0,4096);limit.setSuffix(' GB');limit.setSpecialValueText('不限制');limit.setValue(st.cache_limit_gb)
        form.addRow('缓存上限',limit);v.addLayout(form)
        ask=QCheckBox('视频导出后询问是否保存工程并清理过程文件');ask.setChecked(st.ask_cleanup_after_export);v.addWidget(ask)
        note=QLabel('优先清理较久未使用、可从原片重建的文件。当前任务、工程和编辑记录受保护；保护内容超出上限时会保留并提示。');note.setWordWrap(True);v.addWidget(note)
        if st.cache_message:v.addWidget(QLabel(st.cache_message))
        clean=QPushButton('清理未使用的过程文件')
        def cleanup():
            if st.export_running or st.phase in ('importing','analyzing'):
                QMessageBox.information(d,'任务进行中','请先完成或取消当前任务。');return
            report=cache_policy.clean(st.cache.root,0,st.protected_cache());usage.setText(f'缓存占用 {report["after"]/(1<<30):.2f} GB，已释放 {report["removed"]/(1<<30):.2f} GB')
        clean.clicked.connect(cleanup);v.addWidget(clean)
        buttons=QDialogButtonBox(QDialogButtonBox.Save|QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Save).setText("保存");buttons.button(QDialogButtonBox.Cancel).setText("取消")
        buttons.accepted.connect(d.accept);buttons.rejected.connect(d.reject);v.addWidget(buttons)
        if d.exec()==QDialog.Accepted:
            st.cache_limit_gb=limit.value();st.ask_cleanup_after_export=ask.isChecked();st.save_settings();st.trim_cache()
