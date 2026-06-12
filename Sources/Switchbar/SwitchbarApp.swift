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
                Button("Settings...") {
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

    func showSettings() {
        settingsWindowController.show(model: model)
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
    }

    private func registerHotKey(for model: BrowserModel) {
        hotKeyController.register(model.globalHotKey) { [weak self] in
            self?.statusController.showMenu()
        }
    }
}
