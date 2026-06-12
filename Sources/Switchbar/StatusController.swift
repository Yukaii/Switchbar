import AppKit
import SwiftUI

@MainActor
final class StatusController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var model: BrowserModel?

    func bind(_ model: BrowserModel) {
        self.model = model
        rebuildMenu()
    }

    func rebuildFromModelChange() {
        rebuildMenu()
    }

    func showMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = statusItem.menu ?? NSMenu()
        button.performClick(nil)
    }

    private func rebuildMenu() {
        guard let model else { return }

        if let button = statusItem.button {
            button.isHidden = model.hidesMenuBarIcon
            button.toolTip = "Switchbar"
            button.image = NSImage(systemSymbolName: model.menuBarIconMode.systemImage, accessibilityDescription: "Switchbar")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        for (index, browser) in model.visibleBrowsers.enumerated() {
            let keyEquivalent = index < 9 ? String(index + 1) : ""
            let item = NSMenuItem(title: browser.name, action: #selector(selectBrowser(_:)), keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = browser.id
            item.state = browser.id == model.selectedBrowserID ? .on : .off
            item.image = menuIcon(for: browser, model: model)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Switchbar", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func menuIcon(for browser: Browser, model: BrowserModel) -> NSImage {
        let image = model.icon(for: browser).copy() as? NSImage ?? model.icon(for: browser)
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func selectBrowser(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let browser = model?.browsers.first(where: { $0.id == id })
        else { return }

        model?.choose(browser)
    }

    @objc private func openSettings() {
        AppState.shared.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
