import AppKit
import SwiftUI
import BirdLockCore

/// One editable field for both catalogue search and explicit profile selection.
struct SearchableLensPicker: NSViewRepresentable {
    let entries: [LensCatalogEntry]
    let selectedURL: URL?
    let selectedName: String
    var onSelect: (URL?) -> Bool
    var onSearch: (Bool, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = true; box.dataSource = context.coordinator; box.delegate = context.coordinator
        box.isEditable = true; box.completes = false; box.hasVerticalScroller = true
        box.numberOfVisibleItems = 9; box.placeholderString = "选择或搜索机身、镜头、焦距、模式"
        box.setAccessibilityLabel("镜头组合，输入关键词搜索")
        box.font = .systemFont(ofSize: NSFont.systemFontSize)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.refresh(box)
        return box
    }
    func updateNSView(_ box: NSComboBox, context: Context) {
        let c = context.coordinator
        let changed = c.parent.selectedURL != selectedURL || c.parent.selectedName != selectedName
        c.parent = self
        if changed || !c.searching { c.refresh(box) }
    }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: SearchableLensPicker
        var visible: [LensCatalogEntry] = []
        var searching = false
        private var updating = false
        init(_ parent: SearchableLensPicker) { self.parent = parent }
        func refresh(_ box: NSComboBox) {
            updating = true; defer { updating = false }
            searching = false; visible = parent.entries; box.reloadData()
            box.stringValue = parent.selectedURL == nil ? "" : parent.selectedName
            box.toolTip = parent.selectedURL == nil ? "输入关键词筛选，按回车选择；Esc 取消搜索。镜头校正为可选项。" : parent.selectedName
        }
        func numberOfItems(in comboBox: NSComboBox) -> Int { visible.count + (searching ? 0 : 1) }
        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            if !searching && index == 0 { return "不使用镜头配置" }
            let i = index - (searching ? 0 : 1)
            return visible.indices.contains(i) ? visible[i].title : nil
        }
        func comboBoxWillPopUp(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            if !searching { visible = parent.entries; box.reloadData() }
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox else { return }
            let i = box.indexOfSelectedItem - (searching ? 0 : 1)
            if !searching && box.indexOfSelectedItem == 0 { commit(nil, box) }
            else if visible.indices.contains(i) { commit(visible[i].url, box) }
        }
        func comboBoxWillDismiss(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            // Wait for the selection notification; only an uncommitted dismissal restores the old value.
            DispatchQueue.main.async { [weak self, weak box] in
                guard let self, let box, self.searching else { return }
                self.refresh(box); self.parent.onSearch(false,self.visible.count)
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox else { return }
            let text = box.stringValue
            if text.isEmpty { commit(nil,box); return }
            searching = true; visible = LensCatalog.search(text,in:parent.entries)
            updating = true
            if box.indexOfSelectedItem >= 0 { box.deselectItem(at:box.indexOfSelectedItem) }
            box.reloadData(); updating = false
            parent.onSearch(true,visible.count)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let box = control as? NSComboBox else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)), searching {
                refresh(box); parent.onSearch(false,visible.count); return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)), searching {
                if let first = visible.first { commit(first.url,box) } else { NSSound.beep() }
                return true
            }
            return false
        }
        private func commit(_ url: URL?, _ box: NSComboBox) {
            guard !updating else { return }
            _ = parent.onSelect(url)
            // The parent validates before changing the committed profile. SwiftUI supplies its title.
            searching = false; parent.onSearch(false,visible.count)
            if url == nil { box.stringValue = "" }
        }
    }
}
