// ============================================================
//  RootView — onboarding gate, global key handling, toasts
// ============================================================
import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppState.self) var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            if app.onboarded || app.isLoadingCatalog {
                MainView()
                    .transition(.opacity)
                    .overlay {
                        if app.isLoadingCatalog && !app.hasCatalogPreview {
                            ZStack {
                                Theme.bgContent.opacity(0.94)
                                VStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在打开 \(app.catalogDisplayName)…")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.text2)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
            } else {
                ZStack {
                    Theme.bgDesktop.ignoresSafeArea()
                    WelcomeView()
                        .scaleEffect(app.welcomeAnim ? 1.02 : 1)
                        .opacity(app.welcomeAnim ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.4), value: app.welcomeAnim)
            }
            ToastOverlay(center: app.toastCenter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDesktop.ignoresSafeArea())
        .background(KeyCatcher(app: app))
        .onChange(of: app.settingsRequest) { openSettings() }
    }
}

// ---------- Toasts ----------
struct ToastOverlay: View {
    let center: ToastCenter   // @Observable: body reads register automatically
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                ForEach(center.toasts) { toast in
                    HStack(spacing: 8) {
                        Icon(toast.icon, size: 14).foregroundStyle(Theme.accent)
                        Text(toast.message).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 9)
                    .background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.r)
                        .strokeBorder(Theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.r))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 40)
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: center.toasts)
    }
}

// ---------- Global key handling via NSEvent monitor ----------
struct KeyCatcher: NSViewRepresentable {
    let app: AppState

    nonisolated static func shouldPassThroughGlobalShortcut(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.option, .control]).isEmpty
    }

    nonisolated static func shouldPassThroughMenuCommand(_ key: String, hasCommand: Bool) -> Bool {
        guard hasCommand else { return false }
        return [
            "n", "o", "i", ",", "e", "delete", "backspace",
            "f", "=", "+", "-", "0", "r", "b", "s",
        ].contains(key)
    }

    /// SwiftUI writes a command's enabled state into its menu item only when that menu opens,
    /// so a shortcut is matched against whatever the item showed last: ⇧⌘E stayed disabled
    /// from launch (no selection yet) until the 照片 menu was opened by hand.
    @MainActor
    static func refreshMenuItems() {
        func refresh(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
        }
        if let menu = NSApp.mainMenu { refresh(menu) }
    }

    @MainActor
    static func isEditingText() -> Bool {
        if isTextInput(NSApp.keyWindow?.firstResponder) { return true }
        // A system panel can hold key status for a moment once typing starts (SPRoundedWindow, the
        // indicator beside the caret); the field being typed into is still the main window's, and
        // reading only the key window turned the next letters into shortcuts (x rejected the photo).
        // A sheet answers for itself so Escape still closes it.
        let key = NSApp.keyWindow
        guard key?.sheetParent == nil, let main = NSApp.mainWindow, key !== main else { return false }
        return isTextInput(main.firstResponder)
    }

    /// Whether `responder` takes typed text: a text view (every text field edits in one), or a date
    /// picker, which reads digits itself with no field editor (the filter bar's custom range: typing
    /// a date rated the photo).
    @MainActor
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSDatePicker
    }

    nonisolated static func keyString(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        switch keyCode {
        case 0:
            // A on QWERTY even where the layout types no Latin letter there (⌘A selects all), but the
            // layout's own letter where it has one: on AZERTY that key is Q, and ⌘Q quits
            let typed = (charactersIgnoringModifiers ?? "").lowercased()
            return typed.count == 1 && typed.allSatisfy { ("a"..."z").contains($0) } ? typed : "a"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 36, 76: return "return"
        case 53: return "escape"
        case 48: return "tab"
        // Digits by position: with Shift held (rate-and-advance) the characters are "!@#…".
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 51: return "backspace"
        case 117: return "delete"
        case 49: return " "
        default: return (charactersIgnoringModifiers ?? "").lowercased()
        }
    }

    /// Whether `window` is a sheet over the library's window, which takes the keys while it's up.
    @MainActor
    static func isSheet(_ window: NSWindow?, of hostWindow: NSWindow?,
                        sheetParent: @MainActor (NSWindow) -> NSWindow? = { $0.sheetParent }) -> Bool {
        guard let window, let hostWindow, window !== hostWindow else { return false }
        return sheetParent(window) === hostWindow
    }

    @MainActor
    static func routeEvent(_ event: NSEvent, hostWindow: NSWindow?, presentsSheet: Bool = false,
                           isMenuTracking: Bool, isEditingText: Bool, isComposingText: Bool = false,
                           sheetParent: @MainActor (NSWindow) -> NSWindow? = { $0.sheetParent },
                           handle: (String, Bool, Bool) -> Bool) -> NSEvent? {
        guard let hostWindow, !isMenuTracking,
              !shouldPassThroughGlobalShortcut(event.modifierFlags) else { return event }
        let command = event.modifierFlags.contains(.command)
        let key = keyString(keyCode: event.keyCode,
                            charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        let shift = event.modifierFlags.contains(.shift)
        if event.window !== hostWindow {
            // A sheet is a window of its own. Esc closes it, from one of its text fields too, as a
            // Cancel button would (unless an input method is composing: Esc ends that first); the
            // library's ⌘ shortcuts are kept from the photos behind it, except while a field takes
            // them (⌘A, ⌘⌫). Its other keys, and every other window's, stay theirs.
            guard presentsSheet, isSheet(event.window, of: hostWindow, sheetParent: sheetParent) else { return event }
            let closes = key == "escape" && !command && !isComposingText
            guard closes || (command && !isEditingText) else { return event }
            return handle(key, command, shift) ? nil : event
        }
        guard !isEditingText, !shouldPassThroughMenuCommand(key, hasCommand: command) else { return event }
        return handle(key, command, shift) ? nil : event
    }

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(in: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        let app: AppState
        private var monitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var menuTrackingDepth = 0
        init(app: AppState) { self.app = app }

        func install(in view: NSView) {
            remove()
            // Native menus can leave the main window's responder unchanged.
            menuObservers = [
                NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                       object: nil, queue: nil) { [weak self] _ in
                    self?.menuTrackingDepth += 1
                },
                NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                       object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                },
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self else { return event }
                return self.handle(event, hostView: view)
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
            menuObservers = []
            menuTrackingDepth = 0
        }

        private func handle(_ event: NSEvent, hostView: NSView?) -> NSEvent? {
            // the slideshow takes its own keys
            if event.window is SlideshowWindow { return event }
            let app = app
            let handled = MainActor.assumeIsolated {
                let hostWindow = hostView?.window
                // a sheet's too: a menu item still enabled from before the sheet would act behind it
                if let hostWindow, event.window === hostWindow || KeyCatcher.isSheet(event.window, of: hostWindow),
                   event.modifierFlags.contains(.command) {
                    KeyCatcher.refreshMenuItems()
                }
                let composing = (event.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
                return KeyCatcher.routeEvent(event, hostWindow: hostWindow, presentsSheet: app.sheet != nil,
                                             isMenuTracking: menuTrackingDepth > 0,
                                             isEditingText: KeyCatcher.isEditingText(),
                                             isComposingText: composing) { key, command, shift in
                    app.handleKey(key, hasCommand: command, hasShift: shift)
                } == nil
            }
            return handled ? nil : event
        }

    }
}
