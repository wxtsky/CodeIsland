import AppKit

extension UserDefaults {
    @objc dynamic var hideWhenNoSession: Bool {
        bool(forKey: SettingsKey.hideWhenNoSession)
    }
}

@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var observation: NSKeyValueObservation?
    private lazy var menu: NSMenu = makeMenu()

    func startObserving() {
        syncVisibility()
        observation = UserDefaults.standard.observe(
            \.hideWhenNoSession, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.syncVisibility() }
        }
    }

    private func syncVisibility() {
        showStatusItem()
    }

    private func showStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = Self.menuBarIcon()
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = "CodeIsland"
            }
            item.menu = menu
            statusItem = item
        }
    }

    /// Menu-bar art is a *template* image by macOS convention (#313): alpha-only
    /// artwork that AppKit tints itself, so it tracks light/dark, the menu bar's
    /// own tint over a wallpaper, and the pressed/highlighted state. The
    /// full-colour app icon can do none of that and reads as a foreign sticker
    /// next to every system item.
    ///
    /// The mark is the island itself — a pill with the mascot's two eyes knocked
    /// out, which still resolves at 18pt where a scaled-down app icon turns to mush.
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let pill = NSRect(x: 1.5, y: 5, width: 15, height: 8)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()

            ctx.saveGraphicsState()
            ctx.compositingOperation = .destinationOut
            let eye = CGFloat(2.6)
            for dx in [-3.7, 1.1] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(
                    x: pill.midX + dx,
                    y: pill.midY - eye / 2,
                    width: eye,
                    height: eye
                )).fill()
            }
            ctx.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func hideStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: L10n.shared["settings_ellipsis"],
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.shared["quit"],
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openSettings() {
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
