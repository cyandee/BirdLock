"""Selection lives beside composition; original-image tools perform the actual point/box picks."""
from PySide6.QtWidgets import QPushButton,QHBoxLayout
from .inspector import Card,caption


class TrackingCard(Card):
    def __init__(self,state):
        super().__init__('锁定目标','◎');self.state=state
        self.note=caption('');self.add(self.note)
        self.pick=QPushButton('');self.pick.clicked.connect(self.begin);self.add(self.pick)
        row=QHBoxLayout();self.auto=QPushButton('恢复自动');self.auto.clicked.connect(state.automatic_eye);row.addWidget(self.auto)
        self.undo=QPushButton('撤销选眼');self.undo.clicked.connect(state.undo_eye_selection);row.addWidget(self.undo);self.add(row)
        self.remove=QPushButton('移除当前参考关键帧');self.remove.clicked.connect(state.remove_custom_seed);self.add(self.remove)
        self.message=caption('');self.add(self.message)
        state.changed.connect(self.refresh);self.refresh('all')

    def begin(self):
        if self.state.subject=='custom':self.state.begin_custom_box()
        else:self.state.begin_picking_eye()

    def refresh(self,topic):
        if topic not in ('all','analysis','phase','subject','frame','tool'):return
        st=self.state;a=st.analysis;custom=st.subject=='custom'
        self.setVisible(st.subject!='aircraft');self.setEnabled(st.phase=='ready')
        self.pick.setText('框选目标 / 添加关键帧' if custom else '在原图点选要固定的眼睛')
        self.auto.setVisible(not custom)
        self.undo.setVisible(not custom and bool(st.eye_undo) and a is not None and st.eye_undo[0]==a.fingerprint)
        self.remove.setVisible(custom and a is not None and any(s['frame']==st.current_frame for s in a.customSeeds))
        if custom:
            count=sum(s['frame'] in a.clip_range(st.current_frame) for s in a.customSeeds) if a else 0
            self.note.setText(f'先框选稳定区域，再点击框内锁定点。从任意一张开始，失锁处补选关键帧。本组 {count} 个参考。')
        else:
            fixed=a is not None and a.selected_eye(st.current_frame) is not None
            self.note.setText(('本组已固定同一只眼睛。' if fixed else '自动：随可见性选择眼睛。')+'可先查看末尾再选眼；已有手动修正优先。')
        self.message.setText(st.timeline_message);self.message.setVisible(bool(st.timeline_message))
