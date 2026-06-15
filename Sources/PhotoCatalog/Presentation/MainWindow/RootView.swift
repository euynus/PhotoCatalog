// ============================================================
//  RootView — onboarding gate, global key handling, toasts
// ============================================================
import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            if app.onboarded {
                MainView()
                    .transition(.opacity)
            } else {
                ZStack {
                    RadialGradient(
                        colors: [Color(hex: "#2a2320"), Theme.bgDesktop],
                        center: .top, startRadius: 0, endRadius: 900)
                        .ignoresSafeArea()
                    WelcomeView()
                        .scaleEffect(app.welcomeAnim ? 1.02 : 1)
                        .opacity(app.welcomeAnim ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.4), value: app.welcomeAnim)
            }
            ToastOverlay()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDesktop.ignoresSafeArea())
        .background(KeyCatcher(app: app))
    }
}

// ---------- Toasts ----------
struct ToastOverlay: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                ForEach(app.toasts) { toast in
                    HStack(spacing: 8) {
                        Icon(toast.icon, size: 14).foregroundStyle(Theme.accent)
                        Text(toast.message).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 9)
                    .background(Color(hex: "#2c2c2e").opacity(0.96))
                    .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.5), radius: 17, y: 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 40)
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: app.toasts)
    }
}

// ---------- Global key handling via NSEvent monitor ----------
struct KeyCatcher: NSViewRepresentable {
    let app: AppState

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
            MainActor.assumeIsolated {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return true }
                return false
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let key = Self.keyString(event)
            let app = app

            if isEditingText() { return event }

            let handled = MainActor.assumeIsolated {
                app.handleKey(key, hasCommand: cmd, hasShift: shift)
            }
            return handled ? nil : event
        }

        private static func keyString(_ event: NSEvent) -> String {
            switch event.keyCode {
            case 123: return "left"
            case 124: return "right"
            case 125: return "down"
            case 126: return "up"
            case 51: return "backspace"
            case 117: return "delete"
            case 49: return " "
            default: return (event.charactersIgnoringModifiers ?? "").lowercased()
            }
        }
    }
}
