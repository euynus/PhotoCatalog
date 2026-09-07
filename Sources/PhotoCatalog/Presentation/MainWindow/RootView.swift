// ============================================================
//  RootView — onboarding gate, global key handling, toasts
// ============================================================
import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppState.self) var app

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

    @MainActor
    static func isEditingText() -> Bool {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return true }
        return false
    }

    nonisolated static func keyString(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        switch keyCode {
        case 0: return "a"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 36, 76: return "return"
        case 53: return "escape"
        case 51: return "backspace"
        case 117: return "delete"
        case 49: return " "
        default: return (charactersIgnoringModifiers ?? "").lowercased()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        let app: AppState
        private var monitor: Any?
        init(app: AppState) { self.app = app }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func isEditingText() -> Bool {
            MainActor.assumeIsolated { KeyCatcher.isEditingText() }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            if KeyCatcher.shouldPassThroughGlobalShortcut(event.modifierFlags) { return event }
            let key = KeyCatcher.keyString(keyCode: event.keyCode,
                                           charactersIgnoringModifiers: event.charactersIgnoringModifiers)
            let app = app

            if isEditingText() { return event }
            if KeyCatcher.shouldPassThroughMenuCommand(key, hasCommand: cmd) { return event }

            let handled = MainActor.assumeIsolated {
                app.handleKey(key, hasCommand: cmd, hasShift: shift)
            }
            return handled ? nil : event
        }

    }
}
