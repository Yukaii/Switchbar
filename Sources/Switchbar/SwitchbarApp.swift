import AppKit
import SwiftUI

@main
struct SwitchbarApp: App {
    @StateObject private var model = AppState.shared.model
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560, height: 500)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
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

    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusController = StatusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController.bind(AppState.shared.model)
    }
}
