// ============================================================
//  ClickEvent — the mouse click behind a tap gesture
// ============================================================
import AppKit

/// Lets one `.onTapGesture` tell a double-click from a single click. Stacking
/// `.onTapGesture(count: 2)` on a plain one makes SwiftUI hold every single click
/// until the double-click interval has passed (~0.4 s of lag on each selection).
@MainActor
enum ClickEvent {
    /// 2 on the second click of a double-click.
    static var clickCount: Int {
        guard let event = currentClick else { return 1 }
        return event.clickCount
    }

    /// Modifiers held during the click itself; the keyboard may have changed since.
    static var modifierFlags: NSEvent.ModifierFlags {
        currentClick?.modifierFlags ?? NSEvent.modifierFlags
    }

    private static var currentClick: NSEvent? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown else {
            return nil
        }
        return event
    }
}
