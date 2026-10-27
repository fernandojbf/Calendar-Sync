import AppKit
import SwiftUI

/// Shrinks the window showing the view to the view's height, keeping the window's top edge,
/// whenever the view gets shorter.
///
/// `MenuBarExtra`'s window grows with its content and keeps its top edge under the menu bar
/// while doing so, but it never shrinks while open: shorter content (the calendar switched from
/// List to Month, a problem clearing) is centered in the taller window, so the menu hangs below
/// a gap under the menu bar. On the layout pass that lays the shorter content out, this view
/// resizes the window to fit it, keeping the top edge where SwiftUI put it.
struct WindowTopAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        private var isResizing = false

        override func layout() {
            super.layout()
            guard !isResizing, let window else { return }
            // The view is the menu's whole content; the window sizes itself to the content's
            // height rounded up.
            let height = ceil(bounds.height)
            let content = window.contentRect(forFrameRect: window.frame)
            guard height > 0, height < content.height else { return }
            var shorter = content
            shorter.origin.y = content.maxY - height
            shorter.size.height = height
            isResizing = true
            window.setFrame(window.frameRect(forContentRect: shorter), display: true)
            isResizing = false
        }
    }
}
