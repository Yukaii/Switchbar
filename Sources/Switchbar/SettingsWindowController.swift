import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: BrowserModel) {
        if let window {
            show(window)
            return
        }

        let contentView = SettingsView()
            .environmentObject(model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 475, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Default Browser Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: contentView)
        window.center()

        self.window = window
        show(window)
    }

    private func show(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
