import AppKit
import SwiftUI

@MainActor
final class StatusController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menuAnchorWindow: NSPanel = {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.level = .popUpMenu
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return window
    }()
    private weak var model: BrowserModel?

    func bind(_ model: BrowserModel) {
        self.model = model
        rebuildMenu()
    }

    func rebuildFromModelChange() {
        rebuildMenu()
    }

    func showMenu() {
        guard let menu = statusItem.menu else { return }
        menuAnchorWindow.setFrameOrigin(menuAnchorLocation())
        menuAnchorWindow.orderFrontRegardless()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 1), in: menuAnchorWindow.contentView)
        menuAnchorWindow.orderOut(nil)
    }

    private func menuAnchorLocation() -> NSPoint {
        if let button = statusItem.button, let window = button.window, !button.isHidden {
            let buttonFrame = button.convert(button.bounds, to: nil)
            let screenFrame = window.convertToScreen(buttonFrame)
            if isUsableMenuBarFrame(screenFrame) {
                return NSPoint(x: screenFrame.midX, y: screenFrame.minY - 8)
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return mouseLocation }

        return NSPoint(x: screen.frame.maxX - 260, y: screen.visibleFrame.maxY - 8)
    }

    private func isUsableMenuBarFrame(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return false }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY

        return frame.midX > screen.frame.midX
            && frame.minY >= screen.visibleFrame.maxY - 2
            && frame.maxY <= screen.frame.maxY + 2
            && frame.height <= menuBarHeight + 8
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
