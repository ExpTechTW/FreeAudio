import AppKit
import SwiftUI

/// A small badge in the top-right corner of the screen saying what a shortcut just did, like the system's volume and
/// brightness indicators: it never takes focus or clicks, shows over full-screen apps, and fades after a moment. A
/// second press replaces it rather than stacking.
@MainActor
final class OSD {
    static let shared = OSD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Counts showings, so fading out one doesn't hide the next.
    private var generation = 0

    func show(symbol: String, tint: Color, title: String, detail: String?) {
        generation += 1
        let host = NSHostingView(rootView: OSDView(symbol: symbol, tint: tint, title: title, detail: detail))
        let size = host.fittingSize
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = host
        // The screen with the mouse, which is the one being looked at.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        let shown = generation
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    if self?.generation == shown { panel.orderOut(nil) }
                }
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct OSDView: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 200, maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
