"""One editable, keyboard-accessible control for lens search and selection."""
from PySide6.QtCore import QModelIndex, Qt, Signal
from PySide6.QtGui import QStandardItem, QStandardItemModel
from PySide6.QtWidgets import QComboBox, QCompleter
from ..core import lens_catalog


class SearchableLensCombo(QComboBox):
    valueSelected = Signal(str)
    searchEdited = Signal(bool, int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.entries = []
        self.selected_path, self.selected_title = '', ''
        self.searching = False
        self.setEditable(True)
        self.setInsertPolicy(QComboBox.NoInsert)
        self.setMinimumWidth(0)
        self.setSizeAdjustPolicy(QComboBox.AdjustToMinimumContentsLengthWithIcon)
        self.setMinimumContentsLength(12)
        self.setMaxVisibleItems(9)
        self.lineEdit().setPlaceholderText('选择或搜索机身、镜头、焦距、模式')
        self.setAccessibleName('镜头组合，输入关键词搜索')
        self.matches = QStandardItemModel(self)
        completer = QCompleter(self.matches, self)
        completer.setCompletionMode(QCompleter.UnfilteredPopupCompletion)
        completer.setMaxVisibleItems(9)
        self.setCompleter(completer)
        completer.activated[QModelIndex].connect(self._completion_selected)
        self.lineEdit().textEdited.connect(self._edited)
        self.activated.connect(lambda i: self._selected(self.itemData(i) or ''))
        self.lineEdit().installEventFilter(self)
        completer.popup().installEventFilter(self)
        self.set_entries([])

    def set_entries(self, entries):
        self.entries = entries
        self.blockSignals(True)
        self.clear(); self.addItem('不使用镜头配置', '')
        for e in entries: self.addItem(e.title, str(e.url))
        self.blockSignals(False)
        self.set_selection(self.selected_path, self.selected_title)

    def set_selection(self, path, title=''):
        self.completer().popup().hide()
        self.selected_path, self.selected_title = str(path or ''), title
        self.blockSignals(True)
        if path and self.findData(str(path)) < 0: self.addItem(title, str(path))
        self.setCurrentIndex(max(0, self.findData(self.selected_path)))
        self.setEditText(title if path else '')
        self.setToolTip(title if path else '输入关键词筛选，回车选择，Esc取消搜索；镜头校正为可选项。')
        self.blockSignals(False)
        self.searching = False
        self.searchEdited.emit(False, len(self.entries))

    def _edited(self, text):
        if not text:
            self._selected(''); return
        self.searching = True
        visible = lens_catalog.search(text, self.entries)
        self.matches.clear()
        for entry in visible:
            item = QStandardItem(entry.title)
            item.setData(str(entry.url), Qt.UserRole)
            item.setToolTip(entry.title)
            self.matches.appendRow(item)
        if not visible:
            item = QStandardItem('没有匹配的配置，请换关键词或点「查找配置」')
            item.setEnabled(False); self.matches.appendRow(item)
        self.completer().setCompletionPrefix('')
        self.searchEdited.emit(True, len(visible))
        if self.isVisible(): self.completer().complete()

    def _completion_selected(self, index):
        path = index.data(Qt.UserRole)
        if path: self._selected(path)

    def _selected(self, path):
        self.valueSelected.emit(path)
        # The owner validates and commits; a failed choice keeps the previous valid title.
        self.set_selection(self.selected_path, self.selected_title)

    def showPopup(self):
        if self.searching: self.completer().complete()
        else: super().showPopup()

    def eventFilter(self, obj, event):
        from PySide6.QtCore import QEvent
        if obj in (self.lineEdit(),self.completer().popup()) and event.type() == QEvent.KeyPress and self.searching:
            if event.key() == Qt.Key_Escape:
                self.completer().popup().hide()
                self.set_selection(self.selected_path, self.selected_title); return True
            if event.key() in (Qt.Key_Return, Qt.Key_Enter):
                index = self.completer().popup().currentIndex()
                path = index.data(Qt.UserRole) if index.isValid() else None
                if not path and self.matches.rowCount() and self.matches.item(0).isEnabled():
                    path = self.matches.item(0).data(Qt.UserRole)
                if path: self._selected(path)
                self.completer().popup().hide()
                return True
        return super().eventFilter(obj, event)
