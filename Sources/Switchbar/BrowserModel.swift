import AppKit
import Carbon
import CoreServices
import Darwin
import os
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

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayText: String
}

private struct StoredBrowser: Codable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let shortcut: String
}

enum MenuBarIconMode: String, CaseIterable, Identifiable {
    case `switch`
    case globe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .switch: "Switch"
        case .globe: "Globe"
        }
    }

    var systemImage: String {
        switch self {
        case .switch: "arrow.left.arrow.right"
        case .globe: "globe"
        }
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    private enum DefaultsKey {
        static let selectedBrowserID = "selectedBrowserID"
        static let hiddenBrowserIDs = "hiddenBrowserIDs"
        static let hidesMenuBarIcon = "hidesMenuBarIcon"
        static let launchAtLogin = "launchAtLogin"
        static let menuBarIconMode = "menuBarIconMode"
        static let globalShortcut = "globalShortcut"
        static let globalHotKey = "globalHotKey"
        static let discoveredBrowsers = "discoveredBrowsers"
        static let browserOrder = "browserOrder"
    }

    private enum LaunchServices {
        static let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
        static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    }

    private let defaults: UserDefaults
    nonisolated private let logger = Logger(subsystem: "com.switchbar.app", category: "DefaultBrowser")
    private var isSwitchingDefaultBrowser = false
    private var pendingBrowserSwitch: Browser?

    @Published var browsers: [Browser] = [
        Browser(id: "safari", bundleIdentifiers: ["com.apple.Safari"], name: "Safari", accent: .blue, isVisible: true, shortcut: "1"),
        Browser(id: "arc", bundleIdentifiers: ["company.thebrowser.Browser"], name: "Arc", accent: .pink, isVisible: true, shortcut: "2"),
        Browser(id: "firefox", bundleIdentifiers: ["org.mozilla.firefox", "org.mozilla.nightly"], name: "Firefox Nightly", accent: .purple, isVisible: true, shortcut: "3"),
        Browser(id: "chrome", bundleIdentifiers: ["com.google.Chrome"], name: "Chrome", accent: .green, isVisible: true, shortcut: "4"),
        Browser(id: "zen", bundleIdentifiers: ["app.zen-browser.zen"], name: "Zen", accent: .indigo, isVisible: true, shortcut: "5"),
        Browser(id: "brave", bundleIdentifiers: ["com.brave.Browser"], name: "Brave", accent: .orange, isVisible: false, shortcut: "6"),
        Browser(id: "edge", bundleIdentifiers: ["com.microsoft.edgemac"], name: "Microsoft Edge", accent: .cyan, isVisible: false, shortcut: "7")
    ] {
        didSet { notifyChanged() }
    }

    @Published var selectedBrowserID = "safari" {
        didSet { notifyChanged() }
    }

    @Published var hidesMenuBarIcon = false {
        didSet { notifyChanged() }
    }

    @Published var launchAtLogin = false {
        didSet { notifyChanged() }
    }

    @Published var menuBarIconMode = MenuBarIconMode.switch {
        didSet { notifyChanged() }
    }

    @Published var globalShortcut = "⌥ Space" {
        didSet { notifyChanged() }
    }

    @Published var globalHotKey: HotKey? {
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

    var showsMenuBarIcon: Bool {
        get { !hidesMenuBarIcon }
        set { hidesMenuBarIcon = !newValue }
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

    func moveBrowsers(from offsets: IndexSet, to destination: Int) {
        browsers.move(fromOffsets: offsets, toOffset: destination)
    }

    func moveBrowser(id: String, direction: Int) {
        guard let currentIndex = browsers.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = currentIndex + direction
        guard browsers.indices.contains(newIndex) else { return }
        browsers.swapAt(currentIndex, newIndex)
    }

    func addBrowser(from applicationURL: URL) {
        guard
            applicationURL.pathExtension == "app",
            let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        else {
            statusMessage = "Choose a macOS app bundle."
            return
        }

        if let existingBrowser = browserMatching(bundleIdentifier: bundleIdentifier) {
            statusMessage = "\(existingBrowser.name) is already in the browser list."
            return
        }

        let browser = Browser(
            id: discoveredBrowserID(for: bundleIdentifier),
            bundleIdentifiers: [bundleIdentifier],
            name: displayName(for: applicationURL),
            accent: .gray,
            isVisible: true,
            shortcut: nextAvailableShortcut()
        )
        browsers.append(browser)
        statusMessage = "Added \(browser.name) to the browser list."
    }

    func setGlobalHotKey(_ hotKey: HotKey) {
        globalShortcut = hotKey.displayText
        globalHotKey = hotKey
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
        loadDiscoveredBrowsers()

        let hiddenBrowserIDs = Set(defaults.stringArray(forKey: DefaultsKey.hiddenBrowserIDs) ?? [])
        browsers = browsers.map { browser in
            var browser = browser
            browser.isVisible = !hiddenBrowserIDs.contains(browser.id)
            return browser
        }

        let systemDefaultBrowserID = refreshSystemDefaultBrowser()

        if let systemDefaultBrowserID {
            selectedBrowserID = systemDefaultBrowserID
        } else if let savedSelectedBrowserID = defaults.string(forKey: DefaultsKey.selectedBrowserID),
           browsers.contains(where: { $0.id == savedSelectedBrowserID }) {
            selectedBrowserID = savedSelectedBrowserID
        }

        if defaults.object(forKey: DefaultsKey.hidesMenuBarIcon) != nil {
            hidesMenuBarIcon = defaults.bool(forKey: DefaultsKey.hidesMenuBarIcon)
        }

        if defaults.object(forKey: DefaultsKey.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: DefaultsKey.launchAtLogin)
        }

        if let savedMenuBarIconMode = defaults.string(forKey: DefaultsKey.menuBarIconMode),
           let mode = MenuBarIconMode(rawValue: savedMenuBarIconMode) {
            menuBarIconMode = mode
        }

        if let savedGlobalShortcut = defaults.string(forKey: DefaultsKey.globalShortcut) {
            globalShortcut = savedGlobalShortcut
        }

        if let data = defaults.data(forKey: DefaultsKey.globalHotKey),
           let savedHotKey = try? JSONDecoder().decode(HotKey.self, from: data) {
            globalHotKey = savedHotKey
            globalShortcut = savedHotKey.displayText
        } else {
            globalHotKey = HotKey(keyCode: 49, modifiers: UInt32(optionKey), displayText: "⌥ Space")
        }

        applySavedBrowserOrder()

        if !visibleBrowsers.contains(where: { $0.id == selectedBrowserID }) {
            selectedBrowserID = visibleBrowsers.first?.id ?? browsers[0].id
        }

        if systemDefaultBrowserName == selectedBrowser.name {
            statusMessage = "\(selectedBrowser.name) is the current macOS default browser."
        } else {
            statusMessage = "\(selectedBrowser.name) is selected locally."
        }
    }

    private func savePreferences() {
        defaults.set(selectedBrowserID, forKey: DefaultsKey.selectedBrowserID)
        defaults.set(browsers.filter { !$0.isVisible }.map(\.id), forKey: DefaultsKey.hiddenBrowserIDs)
        defaults.set(hidesMenuBarIcon, forKey: DefaultsKey.hidesMenuBarIcon)
        defaults.set(launchAtLogin, forKey: DefaultsKey.launchAtLogin)
        defaults.set(menuBarIconMode.rawValue, forKey: DefaultsKey.menuBarIconMode)
        defaults.set(globalShortcut, forKey: DefaultsKey.globalShortcut)
        if let data = try? JSONEncoder().encode(globalHotKey) {
            defaults.set(data, forKey: DefaultsKey.globalHotKey)
        }
        defaults.set(browsers.map(\.id), forKey: DefaultsKey.browserOrder)
        saveDiscoveredBrowsers()
    }

    @discardableResult
    func refreshSystemDefaultBrowser() -> String? {
        guard
            let testURL = URL(string: "https://example.com"),
            let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
            let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        else {
            systemDefaultBrowserName = nil
            return nil
        }

        let browser = browserMatching(bundleIdentifier: bundleIdentifier)
            ?? discoverBrowser(bundleIdentifier: bundleIdentifier, applicationURL: applicationURL)

        guard let browser else {
            systemDefaultBrowserName = nil
            return nil
        }

        systemDefaultBrowserName = browser.name
        return browser.id
    }

    private func setSystemDefaultBrowser(_ browser: Browser) {
        if isSwitchingDefaultBrowser {
            pendingBrowserSwitch = browser
            statusMessage = "Queued switch to \(browser.name)..."
            logger.info("Switch queued while another rebuild is running: browser=\(browser.name, privacy: .public)")
            return
        }

        guard let applicationURL = installedApplicationURL(for: browser) else {
            logger.error("Switch aborted: \(browser.name, privacy: .public) is not installed")
            statusMessage = "\(browser.name) is not installed, so macOS default was not changed."
            return
        }

        let bundleIdentifier = browser.bundleIdentifiers.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }

        guard let bundleIdentifier else {
            logger.error("Switch aborted: no installed bundle identifier found for \(browser.name, privacy: .public)")
            statusMessage = "\(browser.name) is not installed, so macOS default was not changed."
            return
        }

        logger.info("Switch requested: browser=\(browser.name, privacy: .public), bundle=\(bundleIdentifier, privacy: .public), url=\(applicationURL.path, privacy: .public)")

        isSwitchingDefaultBrowser = true
        statusMessage = "Switching macOS default browser to \(browser.name)..."
        Task.detached { [weak self, browserID = browser.id, browserName = browser.name, bundleIdentifier, applicationURL] in
            let macAdminsResult = self?.setDefaultBrowserUsingLaunchServicesPlist(bundleIdentifier, applicationURL: applicationURL) ?? false
            await MainActor.run {
                guard let self else { return }
                self.logger.info("MacAdmins-style LaunchServices result: success=\(macAdminsResult)")
                if macAdminsResult {
                    let refreshedBrowserID = self.refreshSystemDefaultBrowser()
                    self.logger.info("After MacAdmins-style refresh: expected=\(browserID, privacy: .public), actual=\(refreshedBrowserID ?? "nil", privacy: .public), actualName=\(self.systemDefaultBrowserName ?? "nil", privacy: .public)")
                    self.statusMessage = refreshedBrowserID == browserID
                        ? "\(browserName) is now the macOS default browser."
                        : "Launch Services was rebuilt, but macOS still reports \(self.systemDefaultBrowserName ?? "another browser")."
                } else {
                    self.setDefaultBrowserUsingPublicFallback(bundleIdentifier: bundleIdentifier, browserID: browserID, browserName: browserName)
                }
                self.isSwitchingDefaultBrowser = false
                if let pendingBrowserSwitch = self.pendingBrowserSwitch {
                    self.pendingBrowserSwitch = nil
                    self.setSystemDefaultBrowser(pendingBrowserSwitch)
                }
            }
        }
    }

    private func setDefaultBrowserUsingPublicFallback(bundleIdentifier: String, browserID: String, browserName: String) {
        let preferenceWriteSucceeded = setLaunchServicesHandlersSilently(to: bundleIdentifier)
        logger.info("LaunchServices preference write result: success=\(preferenceWriteSucceeded)")
        if preferenceWriteSucceeded {
            let refreshedBrowserID = refreshSystemDefaultBrowser()
            logger.info("After preference write refresh: expected=\(browserID, privacy: .public), actual=\(refreshedBrowserID ?? "nil", privacy: .public), actualName=\(self.systemDefaultBrowserName ?? "nil", privacy: .public)")
            statusMessage = refreshedBrowserID == browserID
                ? "\(browserName) is now the macOS default browser."
                : "Updated Launch Services, but macOS still reports \(systemDefaultBrowserName ?? "another browser")."
            return
        }

        let httpStatus = LSSetDefaultHandlerForURLScheme("http" as CFString, bundleIdentifier as CFString)
        let httpsStatus = LSSetDefaultHandlerForURLScheme("https" as CFString, bundleIdentifier as CFString)
        logger.info("Public URL scheme results: http=\(httpStatus), https=\(httpsStatus)")

        guard httpStatus == noErr, httpsStatus == noErr else {
            statusMessage = "macOS did not change the default browser. HTTP: \(httpStatus), HTTPS: \(httpsStatus)."
            return
        }

        let refreshedBrowserID = refreshSystemDefaultBrowser()
        logger.info("After public API refresh: expected=\(browserID, privacy: .public), actual=\(refreshedBrowserID ?? "nil", privacy: .public), actualName=\(self.systemDefaultBrowserName ?? "nil", privacy: .public)")
        statusMessage = refreshedBrowserID == browserID
            ? "\(browserName) is now the macOS default browser."
            : "macOS accepted the request, but the current default did not change to \(browserName)."
    }

    func installedApplicationURL(for browser: Browser) -> URL? {
        browser.bundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

    private func setLaunchServicesHandlersSilently(to bundleIdentifier: String) -> Bool {
        guard let launchServicesDefaults = UserDefaults(suiteName: "com.apple.LaunchServices/com.apple.launchservices.secure") else {
            logger.error("LaunchServices preference domain unavailable")
            return false
        }

        var handlers = launchServicesDefaults.array(forKey: "LSHandlers") as? [[String: Any]] ?? []
        logger.info("LaunchServices handlers loaded: count=\(handlers.count)")
        upsertHandler(
            in: &handlers,
            matchingKey: "LSHandlerContentType",
            matchingValue: "com.apple.default-app.web-browser",
            bundleIdentifier: bundleIdentifier
        )
        upsertHandler(
            in: &handlers,
            matchingKey: "LSHandlerURLScheme",
            matchingValue: "http",
            bundleIdentifier: bundleIdentifier
        )
        upsertHandler(
            in: &handlers,
            matchingKey: "LSHandlerURLScheme",
            matchingValue: "https",
            bundleIdentifier: bundleIdentifier
        )

        launchServicesDefaults.set(handlers, forKey: "LSHandlers")
        let synchronized = launchServicesDefaults.synchronize()
        logger.info("LaunchServices handlers synchronized: success=\(synchronized), count=\(handlers.count)")
        return synchronized
    }

    nonisolated private func setDefaultBrowserUsingLaunchServicesPlist(_ bundleIdentifier: String, applicationURL: URL) -> Bool {
        do {
            var plist = try loadLaunchServicesPlist()
            var handlers = plist["LSHandlers"] as? [[String: Any]] ?? []
            logger.info("File plist handlers loaded: count=\(handlers.count), path=\(LaunchServices.plistURL.path, privacy: .public)")

            removeBrowserHandlers(from: &handlers)
            handlers.append(contentsOf: browserHandlers(for: bundleIdentifier))
            plist["LSHandlers"] = handlers

            try writeLaunchServicesPlist(plist)
            logger.info("File plist handlers written: count=\(handlers.count)")

            let registerAppResult = runCommand(
                LaunchServices.lsregisterPath,
                arguments: ["-f", applicationURL.path]
            )
            logger.info("lsregister app result: status=\(registerAppResult.status), output=\(registerAppResult.output, privacy: .public)")

            let rescanResult = runCommand(
                LaunchServices.lsregisterPath,
                arguments: ["-gc", "-R", "-all", "user,system,local,network"]
            )
            logger.info("lsregister result: status=\(rescanResult.status), output=\(rescanResult.output, privacy: .public)")

            let killResult = runCommand("/usr/bin/killall", arguments: ["lsd"])
            logger.info("killall lsd result: status=\(killResult.status), output=\(killResult.output, privacy: .public)")

            return rescanResult.status == 0 && (killResult.status == 0 || killResult.status == 1)
        } catch {
            logger.error("MacAdmins-style LaunchServices update failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated private func loadLaunchServicesPlist() throws -> [String: Any] {
        let directoryURL = LaunchServices.plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: LaunchServices.plistURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: LaunchServices.plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist ?? [:]
    }

    nonisolated private func writeLaunchServicesPlist(_ plist: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: LaunchServices.plistURL, options: .atomic)
    }

    nonisolated private func removeBrowserHandlers(from handlers: inout [[String: Any]]) {
        let contentTypes = Set([
            "com.apple.default-app.web-browser",
            "public.url",
            "public.xhtml",
            "public.html"
        ])
        let urlSchemes = Set(["http", "https"])

        handlers.removeAll { handler in
            if let contentType = handler["LSHandlerContentType"] as? String {
                return contentTypes.contains(contentType)
            }
            if let urlScheme = handler["LSHandlerURLScheme"] as? String {
                return urlSchemes.contains(urlScheme)
            }
            return false
        }
    }

    nonisolated private func browserHandlers(for bundleIdentifier: String) -> [[String: Any]] {
        [
            [
                "LSHandlerContentType": "com.apple.default-app.web-browser",
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
                "LSHandlerRoleAll": bundleIdentifier
            ],
            [
                "LSHandlerContentType": "public.url",
                "LSHandlerPreferredVersions": ["LSHandlerRoleViewer": "-"],
                "LSHandlerRoleViewer": bundleIdentifier
            ],
            [
                "LSHandlerContentType": "public.xhtml",
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
                "LSHandlerRoleAll": bundleIdentifier
            ],
            [
                "LSHandlerContentType": "public.html",
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
                "LSHandlerRoleAll": bundleIdentifier
            ],
            [
                "LSHandlerURLScheme": "https",
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
                "LSHandlerRoleAll": bundleIdentifier
            ],
            [
                "LSHandlerURLScheme": "http",
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
                "LSHandlerRoleAll": bundleIdentifier
            ]
        ]
    }

    nonisolated private func runCommand(_ path: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func upsertHandler(
        in handlers: inout [[String: Any]],
        matchingKey: String,
        matchingValue: String,
        bundleIdentifier: String
    ) {
        let handler: [String: Any] = [
            matchingKey: matchingValue,
            "LSHandlerRoleAll": bundleIdentifier,
            "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
            "LSHandlerModificationDate": Int(Date().timeIntervalSinceReferenceDate)
        ]

        if let index = handlers.firstIndex(where: { $0[matchingKey] as? String == matchingValue }) {
            handlers[index] = handler
        } else {
            handlers.append(handler)
        }
    }

    private func browserMatching(bundleIdentifier: String) -> Browser? {
        browsers.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    private func discoverBrowser(bundleIdentifier: String, applicationURL: URL) -> Browser? {
        guard !browsers.contains(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) else {
            return browserMatching(bundleIdentifier: bundleIdentifier)
        }

        let browser = Browser(
            id: discoveredBrowserID(for: bundleIdentifier),
            bundleIdentifiers: [bundleIdentifier],
            name: displayName(for: applicationURL),
            accent: .gray,
            isVisible: true,
            shortcut: nextAvailableShortcut()
        )

        browsers.append(browser)
        saveDiscoveredBrowsers()
        return browser
    }

    private func loadDiscoveredBrowsers() {
        guard let data = defaults.data(forKey: DefaultsKey.discoveredBrowsers) else { return }

        let storedBrowsers = (try? JSONDecoder().decode([StoredBrowser].self, from: data)) ?? []
        for storedBrowser in storedBrowsers where browserMatching(bundleIdentifier: storedBrowser.bundleIdentifier) == nil {
            browsers.append(
                Browser(
                    id: storedBrowser.id,
                    bundleIdentifiers: [storedBrowser.bundleIdentifier],
                    name: storedBrowser.name,
                    accent: .gray,
                    isVisible: true,
                    shortcut: storedBrowser.shortcut
                )
            )
        }
    }

    private func saveDiscoveredBrowsers() {
        let builtInBrowserIDs = Set(["safari", "arc", "firefox", "chrome", "zen", "brave", "edge"])
        let storedBrowsers = browsers
            .filter { !builtInBrowserIDs.contains($0.id) }
            .compactMap { browser -> StoredBrowser? in
                guard let bundleIdentifier = browser.bundleIdentifiers.first else { return nil }
                return StoredBrowser(
                    id: browser.id,
                    bundleIdentifier: bundleIdentifier,
                    name: browser.name,
                    shortcut: browser.shortcut
                )
            }

        guard let data = try? JSONEncoder().encode(storedBrowsers) else { return }
        defaults.set(data, forKey: DefaultsKey.discoveredBrowsers)
    }

    private func applySavedBrowserOrder() {
        guard let browserOrder = defaults.stringArray(forKey: DefaultsKey.browserOrder), !browserOrder.isEmpty else {
            return
        }

        let orderIndex = Dictionary(uniqueKeysWithValues: browserOrder.enumerated().map { ($0.element, $0.offset) })
        browsers.sort {
            (orderIndex[$0.id] ?? Int.max) < (orderIndex[$1.id] ?? Int.max)
        }
    }

    private func discoveredBrowserID(for bundleIdentifier: String) -> String {
        let sanitizedID = bundleIdentifier
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
        return "discovered-" + String(sanitizedID)
    }

    private func displayName(for applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        let bundleDisplayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return bundleDisplayName ?? bundleName ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    private func nextAvailableShortcut() -> String {
        let usedShortcuts = Set(browsers.map(\.shortcut))
        for number in 1...9 where !usedShortcuts.contains(String(number)) {
            return String(number)
        }
        return ""
    }
}
