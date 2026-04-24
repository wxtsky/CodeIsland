import AppKit
import SwiftUI

@MainActor
class PlanPreviewWindowController {
    static let shared = PlanPreviewWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    func show(planText: String) {
        NSApp.setActivationPolicy(.regular)

        if let window = window {
            (window.contentView as? NSHostingView<PlanPreviewView>)?.rootView = PlanPreviewView(plan: planText)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: PlanPreviewView(plan: planText))

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(720, screenW * 0.55)
        let winH = min(600, screenH * 0.65)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = "Plan"
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window = nil
                self?.clearCloseObserver()
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.window = window
    }

    func close() {
        window?.close()
    }
}

private struct PlanPreviewView: View {
    let plan: String

    var body: some View {
        ScrollView {
            Text(plan)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }
}
