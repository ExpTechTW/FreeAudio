import AppKit

/// An alert that doesn't block the rest of the app: the menu bar panel, Settings and Quit keep working while it's up.
@MainActor
final class WarningPanel: NSObject {
    private let alert = NSAlert()
    private var actions: [() -> Void] = []
    private let onClose: () -> Void

    init(title: String, text: String, buttons: [(title: String, action: () -> Void)], onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = text
        for (index, button) in buttons.enumerated() {
            let control = alert.addButton(withTitle: button.title)
            control.tag = index
            control.target = self
            control.action = #selector(pressed(_:))
            actions.append(button.action)
        }
        alert.layout()
        let window = alert.window
        window.level = .floating
        // Shows on the Space in use, even over a full-screen app.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
    }

    var window: NSWindow { alert.window }

    func show() {
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Visible even when macOS doesn't hand FreeAudio the focus.
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    @objc private func pressed(_ sender: NSButton) {
        close()
        onClose()
        actions[sender.tag]()
    }
}
