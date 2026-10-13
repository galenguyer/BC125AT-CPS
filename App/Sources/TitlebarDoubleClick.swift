import AppKit

/// Double-clicking a window's title bar should zoom it (or whatever System Settings ▸ Desktop &
/// Dock ▸ "Double-click a window's title bar to" says). The toolbar here is mostly SwiftUI
/// content, such as the document title and the scanner status, which takes the clicks before
/// AppKit can, so this handles double-clicks anywhere in the title bar that aren't on a control.
@MainActor
enum TitlebarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        // Local event monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// Returns true if the event was a title bar double-click and has been acted on.
    private static func handle(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2, let window = event.window, !(window is NSPanel),
              window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
              event.locationInWindow.y >= window.contentLayoutRect.maxY,
              let frameView = window.contentView?.superview,
              !isOnControl(frameView.hitTest(event.locationInWindow)) else { return false }

        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "None":
            return false
        case "Minimize":
            window.performMiniaturize(nil)
        default:
            // "Maximize", "Fill", or not set (the default, Zoom).
            window.performZoom(nil)
        }
        return true
    }

    /// Buttons, pop-ups, the search field and other things that use clicks themselves.
    private static func isOnControl(_ view: NSView?) -> Bool {
        var current = view
        while let view = current {
            switch view {
            case let field as NSTextField where field.isEditable || field.isSelectable:
                return true
            case is NSTextField:
                break
            case is NSControl, is NSTextView:
                return true
            default:
                break
            }
            current = view.superview
        }
        return false
    }
}
