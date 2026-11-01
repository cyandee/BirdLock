import SwiftUI
import AppKit

/// Preserve SwiftUI's delegate behavior while asking before the main editing window closes.
struct ProjectWindowGuard: NSViewRepresentable {
    let state: AppState
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeNSView(context:Context) -> GuardView {
        let view=GuardView();view.connect={ [weak coordinator=context.coordinator] window in coordinator?.attach(window) };return view
    }
    func updateNSView(_ view:GuardView,context:Context) {
        if let window=view.window { context.coordinator.attach(window) }
    }
    final class GuardView:NSView {
        var connect:(@MainActor (NSWindow)->Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow();if let window { connect?(window) } }
    }
    final class Coordinator:NSObject,NSWindowDelegate {
        let state:AppState
        var original:(any NSWindowDelegate)?
        init(_ state:AppState) { self.state=state }
        @MainActor func attach(_ window:NSWindow) {
            if window.delegate !== self { original=window.delegate;window.delegate=self }
            window.isDocumentEdited=state.projectDirty
            window.representedURL=state.projectURL
            window.title="BirdLock"+(state.projectURL.map { " · "+$0.lastPathComponent } ?? "")
        }
        func windowShouldClose(_ sender:NSWindow) -> Bool {
            guard state.confirmCanLeave() else { return false }
            let approved=original?.windowShouldClose?(sender) ?? true
            if approved { state.projectCloseApproved=true };return approved
        }
        override func responds(to selector:Selector!) -> Bool { super.responds(to:selector) || (original?.responds(to:selector) ?? false) }
        override func forwardingTarget(for selector:Selector!) -> Any? { original }
    }
}
