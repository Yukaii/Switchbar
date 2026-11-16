import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general
    case browsers
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .browsers: "Browsers"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .browsers: "globe"
        case .about: "info.circle"
        }
    }

    @MainActor
    func makeView(model: BrowserModel) -> AnyView {
        switch self {
        case .general: AnyView(GeneralSettingsView().environmentObject(model))
        case .browsers: AnyView(BrowsersSettingsView().environmentObject(model))
        case .about: AnyView(AboutSettingsView().environmentObject(model))
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var tabViewController: SettingsTabViewController?

    func show(model: BrowserModel, tab: SettingsTab? = nil) {
        model.refresh()

        let window = window ?? makeWindow(model: model)
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabViewController?.selectedTabViewItemIndex = index
        }

        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: BrowserModel) -> NSWindow {
        let tabViewController = SettingsTabViewController()
        tabViewController.tabStyle = .toolbar

        for tab in SettingsTab.allCases {
            let hostingController = NSHostingController(rootView: tab.makeView(model: model))
            hostingController.title = tab.title
            hostingController.sizingOptions = [.preferredContentSize]

            let item = NSTabViewItem(viewController: hostingController)
            item.label = tab.title
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
            tabViewController.addTabViewItem(item)
        }

        let window = SettingsWindow(contentViewController: tabViewController)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(tabViewController.tabViewItems.first?.viewController?.preferredContentSize ?? NSSize(width: 500, height: 400))

        self.tabViewController = tabViewController
        self.window = window
        return window
    }
}

/// Resizes the window to each tab's own size (anchored at the top edge, like
/// System Settings-style preference windows) instead of using the largest tab.
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)

        guard
            let window = view.window,
            let contentSize = tabViewItem?.viewController?.preferredContentSize,
            contentSize != .zero
        else { return }

        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        var frame = window.frame
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// Accessory apps have no visible main menu, so ⌘W would otherwise do nothing.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
