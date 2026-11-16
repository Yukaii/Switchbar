import AppKit
import SwiftUI

@main
struct SwitchbarApp: App {
    @StateObject private var model = AppState.shared.model
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppState.shared.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppState {
    static let shared = AppState()

    let model = BrowserModel()
    private let settingsWindowController = SettingsWindowController()

    private init() {}

    func showSettings(tab: SettingsTab? = nil) {
        settingsWindowController.show(model: model, tab: tab)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusController = StatusController()
    private let hotKeyController = GlobalHotKeyController()
    private var boundModel: BrowserModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppState.shared.model
        boundModel = model
        statusController.bind(model)
        registerHotKey(for: model)
        model.onChange = { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.statusController.rebuildFromModelChange()
                self.registerHotKey(for: model)
            }
        }

        // `open Switchbar.app --args -showSettings browsers` jumps straight to a tab.
        if let tabName = UserDefaults.standard.string(forKey: "showSettings") {
            AppState.shared.showSettings(tab: SettingsTab(rawValue: tabName) ?? .general)
        }

        // `open Switchbar.app --args -showMenu YES` pops the switcher, e.g. for screenshots.
        if UserDefaults.standard.bool(forKey: "showMenu") {
            DispatchQueue.main.async { [weak self] in
                self?.statusController.showMenu()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings. With the
    /// menu bar icon hidden this is the way back in besides the hotkey.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showSettings()
        return false
    }

    private func registerHotKey(for model: BrowserModel) {
        hotKeyController.register(model.globalHotKey) { [weak self] in
            self?.statusController.showMenu()
        }
    }
}
