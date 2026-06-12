import AppKit
import SwiftUI

@MainActor
final class StatusController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var model: BrowserModel?

    func bind(_ model: BrowserModel) {
        self.model = model
        model.onChange = { [weak self] in
            Task { @MainActor in self?.rebuildMenu() }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let model else { return }

        if let button = statusItem.button {
            button.isHidden = model.hidesMenuBarIcon
            button.toolTip = "Switchbar"
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Switchbar")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        for browser in model.visibleBrowsers {
            let item = NSMenuItem(title: browser.name, action: #selector(selectBrowser(_:)), keyEquivalent: browser.shortcut)
            item.target = self
            item.representedObject = browser.id
            item.state = browser.id == model.selectedBrowserID ? .on : .off
            item.image = model.icon(for: browser)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)

        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(menuItem("Set from Shortcut", action: #selector(runShortcut)))
        submenu.addItem(menuItem("Apply Work Focus", action: #selector(applyWorkFocus)))
        submenu.addItem(menuItem("Open Inspiration Website", action: #selector(openWebsite)))
        more.submenu = submenu
        menu.addItem(more)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Switchbar", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectBrowser(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let browser = model?.browsers.first(where: { $0.id == id })
        else { return }

        model?.choose(browser)
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func runShortcut() {
        model?.runShortcutAction(named: "Set Browser")
    }

    @objc private func applyWorkFocus() {
        guard let rule = model?.focusRules.first(where: { $0.focus == "Work" }) else { return }
        model?.applyFocus(rule)
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://sindresorhus.com/default-browser")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
