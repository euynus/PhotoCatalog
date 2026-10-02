// ============================================================
//  Undo steps — one per user action, also for work that finishes later
// ============================================================
import AppKit

/// AppKit groups the undo steps registered while it handles an event and closes the group
/// once the event has been handled. A step registered by work that finishes afterwards —
/// auto tone's measuring, a mask's detection — opens a group that no event closes, so it
/// took in the user's next action too and one ⌘Z undid both. Steps registered outside event
/// handling get a group of their own.
@MainActor
enum UndoSteps {
    /// Set while AppKit dispatches a user event; cleared once its handlers have returned.
    private(set) static var handlingEvent = false
    private static var monitor: Any?

    static func trackEvents() {
        guard monitor == nil else { return }
        let input: NSEvent.EventTypeMask = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: input) { event in
            MainActor.assumeIsolated {
                if !handlingEvent {
                    handlingEvent = true
                    // the main queue gets to this once the event's handlers have returned
                    DispatchQueue.main.async { handlingEvent = false }
                }
            }
            return event
        }
    }

    /// Runs `register` — one registration with `manager`, and its action name — as an undo step
    /// of its own unless AppKit is grouping it with the event being handled.
    static func register(on manager: UndoManager, _ register: () -> Void) {
        guard !handlingEvent, manager.groupsByEvent, manager.groupingLevel == 0,
              !manager.isUndoing, !manager.isRedoing else { return register() }
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        register()
        manager.endUndoGrouping()
        manager.groupsByEvent = true
    }
}
