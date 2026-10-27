import AppKit
import SwiftUI

/// Keeps the top edge of the window showing the view in place when the view changes height.
///
/// AppKit keeps a window's bottom-left corner when it resizes the window, so when the menu's
/// content gets shorter (switching the calendar from List to Month, a problem clearing) the
/// menu would stay put at the bottom and hang below a gap under the menu bar. Putting the
/// top edge back keeps it attached to the menu bar, where `MenuBarExtra` opened it.
struct WindowTopAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        private var observers: [NSObjectProtocol] = []
        /// The window's frame after the last change that was left alone.
        private var lastFrame: NSRect = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            lastFrame = window.frame
            // Without a queue the blocks run as the notification is posted, on the main thread,
            // so the window is put back before it is drawn at the wrong place.
            observers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowDidMove() }
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowDidResize() }
                },
            ]
        }

        private func windowDidMove() {
            guard let window else { return }
            lastFrame = window.frame
        }

        private func windowDidResize() {
            guard let window else { return }
            let previous = lastFrame
            lastFrame = window.frame
            // A resize that moved the origin too placed the window on purpose. One that kept it
            // is AppKit growing or shrinking the window from its bottom-left corner.
            guard lastFrame.origin == previous.origin, lastFrame.height != previous.height else { return }
            window.setFrameOrigin(NSPoint(x: previous.minX, y: previous.maxY - lastFrame.height))
            lastFrame = window.frame
        }
    }
}
