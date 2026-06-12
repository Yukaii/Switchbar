import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

struct Browser: Identifiable, Equatable {
    let id: String
    let bundleIdentifiers: [String]
    var name: String
    var accent: Color
    var isVisible: Bool
    var shortcut: String
}

struct FocusRule: Identifiable {
    let id = UUID()
    var focus: String
    var browserID: String
}

@MainActor
final class BrowserModel: ObservableObject {
    private enum DefaultsKey {
        static let selectedBrowserID = "selectedBrowserID"
        static let hiddenBrowserIDs = "hiddenBrowserIDs"
        static let hidesMenuBarIcon = "hidesMenuBarIcon"
        static let showsDefaultBrowserIcon = "showsDefaultBrowserIcon"
        static let globalShortcut = "globalShortcut"
    }

    private let defaults: UserDefaults

    @Published var browsers: [Browser] = [
        Browser(id: "safari", bundleIdentifiers: ["com.apple.Safari"], name: "Safari", accent: .blue, isVisible: true, shortcut: "1"),
        Browser(id: "arc", bundleIdentifiers: ["company.thebrowser.Browser"], name: "Arc", accent: .pink, isVisible: true, shortcut: "2"),
        Browser(id: "firefox", bundleIdentifiers: ["org.mozilla.firefox", "org.mozilla.nightly"], name: "Firefox Nightly", accent: .purple, isVisible: true, shortcut: "3"),
        Browser(id: "chrome", bundleIdentifiers: ["com.google.Chrome"], name: "Chrome", accent: .green, isVisible: true, shortcut: "4"),
        Browser(id: "brave", bundleIdentifiers: ["com.brave.Browser"], name: "Brave", accent: .orange, isVisible: false, shortcut: "5"),
        Browser(id: "edge", bundleIdentifiers: ["com.microsoft.edgemac"], name: "Microsoft Edge", accent: .cyan, isVisible: false, shortcut: "6")
    ] {
        didSet { notifyChanged() }
    }

    @Published var selectedBrowserID = "safari" {
        didSet { notifyChanged() }
    }

    @Published var hidesMenuBarIcon = false {
        didSet { notifyChanged() }
    }

    @Published var showsDefaultBrowserIcon = true {
        didSet { notifyChanged() }
    }

    @Published var globalShortcut = "⌥ Space" {
        didSet { notifyChanged() }
    }

    @Published var statusMessage = "Safari is the simulated system default browser."
    @Published private(set) var systemDefaultBrowserName: String?
    @Published var focusRules: [FocusRule] = [
        FocusRule(focus: "Work", browserID: "arc"),
        FocusRule(focus: "Personal", browserID: "safari"),
        FocusRule(focus: "Development", browserID: "firefox")
    ] {
        didSet { notifyChanged() }
    }

    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPreferences()
    }

    var selectedBrowser: Browser {
        browsers.first(where: { $0.id == selectedBrowserID }) ?? browsers[0]
    }

    var visibleBrowsers: [Browser] {
        browsers.filter(\.isVisible)
    }

    func choose(_ browser: Browser) {
        selectedBrowserID = browser.id
        setSystemDefaultBrowser(browser)
    }

    func toggleVisibility(for browser: Browser) {
        guard let index = browsers.firstIndex(of: browser) else { return }
        browsers[index].isVisible.toggle()
        if !browsers[index].isVisible && browsers[index].id == selectedBrowserID {
            selectedBrowserID = visibleBrowsers.first?.id ?? browsers[index].id
        }
    }

    func applyFocus(_ focusRule: FocusRule) {
        if let browser = browsers.first(where: { $0.id == focusRule.browserID }) {
            choose(browser)
            statusMessage = "\(focusRule.focus) Focus switched the simulated default to \(browser.name)."
        }
    }

    func runShortcutAction(named action: String) {
        statusMessage = "Shortcuts action '\(action)' ran locally."
    }

    func icon(for browser: Browser) -> NSImage {
        guard let applicationURL = installedApplicationURL(for: browser) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }

        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    private func notifyChanged() {
        savePreferences()
        onChange?()
    }

    private func loadPreferences() {
        let hiddenBrowserIDs = Set(defaults.stringArray(forKey: DefaultsKey.hiddenBrowserIDs) ?? [])
        browsers = browsers.map { browser in
            var browser = browser
            browser.isVisible = !hiddenBrowserIDs.contains(browser.id)
            return browser
        }

        let systemDefaultBrowserID = refreshSystemDefaultBrowser()

        if let savedSelectedBrowserID = defaults.string(forKey: DefaultsKey.selectedBrowserID),
           browsers.contains(where: { $0.id == savedSelectedBrowserID }) {
            selectedBrowserID = savedSelectedBrowserID
        } else if let systemDefaultBrowserID {
            selectedBrowserID = systemDefaultBrowserID
        }

        if defaults.object(forKey: DefaultsKey.hidesMenuBarIcon) != nil {
            hidesMenuBarIcon = defaults.bool(forKey: DefaultsKey.hidesMenuBarIcon)
        }

        if defaults.object(forKey: DefaultsKey.showsDefaultBrowserIcon) != nil {
            showsDefaultBrowserIcon = defaults.bool(forKey: DefaultsKey.showsDefaultBrowserIcon)
        }

        if let savedGlobalShortcut = defaults.string(forKey: DefaultsKey.globalShortcut) {
            globalShortcut = savedGlobalShortcut
        }

        if !visibleBrowsers.contains(where: { $0.id == selectedBrowserID }) {
            selectedBrowserID = visibleBrowsers.first?.id ?? browsers[0].id
        }

        if systemDefaultBrowserName == selectedBrowser.name {
            statusMessage = "\(selectedBrowser.name) is the current macOS default browser."
        } else {
            statusMessage = "\(selectedBrowser.name) is the simulated system default browser."
        }
    }

    private func savePreferences() {
        defaults.set(selectedBrowserID, forKey: DefaultsKey.selectedBrowserID)
        defaults.set(browsers.filter { !$0.isVisible }.map(\.id), forKey: DefaultsKey.hiddenBrowserIDs)
        defaults.set(hidesMenuBarIcon, forKey: DefaultsKey.hidesMenuBarIcon)
        defaults.set(showsDefaultBrowserIcon, forKey: DefaultsKey.showsDefaultBrowserIcon)
        defaults.set(globalShortcut, forKey: DefaultsKey.globalShortcut)
    }

    @discardableResult
    func refreshSystemDefaultBrowser() -> String? {
        guard
            let testURL = URL(string: "https://example.com"),
            let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
            let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier,
            let browser = browsers.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) })
        else {
            systemDefaultBrowserName = nil
            return nil
        }

        systemDefaultBrowserName = browser.name
        return browser.id
    }

    private func setSystemDefaultBrowser(_ browser: Browser) {
        guard installedApplicationURL(for: browser) != nil else {
            statusMessage = "\(browser.name) is not installed, so macOS default was not changed."
            return
        }

        let bundleIdentifier = browser.bundleIdentifiers.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }

        guard let bundleIdentifier else {
            statusMessage = "\(browser.name) is not installed, so macOS default was not changed."
            return
        }

        let httpStatus = LSSetDefaultHandlerForURLScheme("http" as CFString, bundleIdentifier as CFString)
        let httpsStatus = LSSetDefaultHandlerForURLScheme("https" as CFString, bundleIdentifier as CFString)

        guard httpStatus == noErr, httpsStatus == noErr else {
            statusMessage = "macOS did not change the default browser. HTTP status: \(httpStatus), HTTPS status: \(httpsStatus)."
            return
        }

        let refreshedBrowserID = refreshSystemDefaultBrowser()
        if refreshedBrowserID == browser.id {
            statusMessage = "\(browser.name) is now the macOS default browser."
        } else {
            statusMessage = "macOS accepted the request, but the current default did not change to \(browser.name)."
        }
    }

    func installedApplicationURL(for browser: Browser) -> URL? {
        browser.bundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

}
