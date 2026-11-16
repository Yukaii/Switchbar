import AppKit
import Carbon
import CoreServices
import Darwin
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Browser: Identifiable, Equatable {
    let id: String
    let bundleIdentifiers: [String]
    var name: String
    var isVisible: Bool
    /// Added by hand (or adopted as the system default) rather than found by the
    /// installed-browser scan. Custom entries are persisted and can be removed.
    var isCustom = false
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
    // Kept optional so preferences written by 1.0.x still decode.
    let shortcut: String?
}

/// An app that LaunchServices reports as able to open web pages.
struct InstalledBrowserApp: Sendable {
    let bundleIdentifier: String
    let url: URL
    let name: String
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
        static let migratedLegacyDefaults = "migratedLegacyDefaults"
    }

    private enum LaunchServices {
        static let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
        static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    }

    /// IDs used by Switchbar 1.0.x's hardcoded browser list. Mapping these bundle
    /// identifiers back to their old IDs keeps saved order/visibility intact.
    private static let legacyBrowserIDs = [
        "com.apple.Safari": "safari",
        "company.thebrowser.Browser": "arc",
        "org.mozilla.firefox": "firefox",
        "com.google.Chrome": "chrome",
        "app.zen-browser.zen": "zen",
        "com.brave.Browser": "brave",
        "com.microsoft.edgemac": "edge"
    ]

    /// ⌥⇧B. Only used when no shortcut has been saved; existing users keep theirs.
    static let defaultHotKey = HotKey(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(optionKey | shiftKey),
        displayText: "⌥ ⇧ B"
    )

    /// Defaults domain used when Switchbar ran as a bare, un-bundled executable.
    private static let legacyDefaultsDomain = "Switchbar"

    private let defaults: UserDefaults
    nonisolated private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "DefaultBrowser")
    private var isSwitchingDefaultBrowser = false
    private var pendingBrowserSwitch: Browser?
    private var switchStartTime: CFAbsoluteTime?
    private var progressTask: Task<Void, Never>?
    private var isLoadingPreferences = false

    /// Hidden/order state for browsers that are not currently installed, so that
    /// uninstalling and reinstalling a browser does not reset its settings.
    private var savedHiddenBrowserIDs: Set<String> = []
    private var savedBrowserOrder: [String] = []
    private var iconCache: [String: NSImage] = [:]

    @Published var browsers: [Browser] = [] {
        didSet { notifyChanged() }
    }

    @Published var selectedBrowserID = "safari" {
        didSet { notifyChanged() }
    }

    @Published var hidesMenuBarIcon = false {
        didSet { notifyChanged() }
    }

    @Published var launchAtLogin = false {
        didSet {
            setLoginItemEnabled(launchAtLogin)
            notifyChanged()
        }
    }

    @Published var menuBarIconMode = MenuBarIconMode.switch {
        didSet { notifyChanged() }
    }

    @Published var globalShortcut = BrowserModel.defaultHotKey.displayText {
        didSet { notifyChanged() }
    }

    @Published var globalHotKey: HotKey? {
        didSet { notifyChanged() }
    }

    @Published var statusMessage = ""
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
        if defaults == .standard {
            migrateLegacyDefaultsIfNeeded()
        }
        loadPreferences()
    }

    var selectedBrowser: Browser? {
        browsers.first(where: { $0.id == selectedBrowserID })
    }

    var visibleBrowsers: [Browser] {
        browsers.filter(\.isVisible)
    }

    /// Browsers that should appear in the switcher menu, in order. Number keys
    /// 1–9 map onto this list.
    var menuBrowsers: [Browser] {
        visibleBrowsers.filter { installedApplicationURL(for: $0) != nil }
    }

    var showsMenuBarIcon: Bool {
        get { !hidesMenuBarIcon }
        set { hidesMenuBarIcon = !newValue }
    }

    /// Whether `SMAppService.mainApp` can work, which needs a real `.app` bundle.
    var canLaunchAtLogin: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func choose(_ browser: Browser) {
        logger.info("choose: selecting browser=\(browser.name, privacy: .public), id=\(browser.id, privacy: .public)")
        selectedBrowserID = browser.id
        systemDefaultBrowserName = browser.name
        statusMessage = "Switching to \(browser.name)..."
        setSystemDefaultBrowser(browser)
    }

    /// Re-scan installed browsers and re-read the real macOS default, so the menu
    /// reflects changes made elsewhere (System Settings, a browser's own
    /// "make default" prompt, installs and uninstalls).
    func refresh() {
        refreshInstalledBrowsers()

        guard !isSwitchingDefaultBrowser, pendingBrowserSwitch == nil else { return }
        guard let systemDefaultBrowserID = refreshSystemDefaultBrowser() else { return }

        if systemDefaultBrowserID != selectedBrowserID {
            logger.info("refresh: system default changed externally to \(systemDefaultBrowserID, privacy: .public)")
            selectedBrowserID = systemDefaultBrowserID
            if let selectedBrowser {
                statusMessage = "\(selectedBrowser.name) is the current macOS default browser."
            }
        }
    }

    func toggleVisibility(for browser: Browser) {
        guard let index = browsers.firstIndex(where: { $0.id == browser.id }) else { return }
        browsers[index].isVisible.toggle()
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

    func moveBrowserToTop(id: String) {
        guard let index = browsers.firstIndex(where: { $0.id == id }), index > 0 else { return }
        browsers.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
    }

    func removeBrowser(id: String) {
        guard let browser = browsers.first(where: { $0.id == id }), browser.isCustom else { return }
        browsers.removeAll { $0.id == id }
        if selectedBrowserID == id, let first = menuBrowsers.first {
            selectedBrowserID = first.id
        }
        statusMessage = "Removed \(browser.name) from the browser list."
    }

    func addBrowser(from applicationURL: URL, at index: Int? = nil) {
        guard
            applicationURL.pathExtension == "app",
            let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        else {
            statusMessage = "Choose a macOS app bundle."
            return
        }

        if let existingIndex = browsers.firstIndex(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) {
            // Dropping an existing browser re-positions it and makes sure it is shown.
            var existing = browsers[existingIndex]
            existing.isVisible = true
            browsers.remove(at: existingIndex)
            let target = min(index.map { $0 > existingIndex ? $0 - 1 : $0 } ?? existingIndex, browsers.count)
            browsers.insert(existing, at: target)
            statusMessage = "\(existing.name) is already in the browser list."
            return
        }

        let browser = Browser(
            id: browserID(for: bundleIdentifier),
            bundleIdentifiers: [bundleIdentifier],
            name: Self.displayName(for: applicationURL),
            isVisible: true,
            isCustom: true
        )
        browsers.insert(browser, at: min(index ?? browsers.count, browsers.count))
        statusMessage = "Added \(browser.name) to the browser list."
    }

    func setGlobalHotKey(_ hotKey: HotKey) {
        globalShortcut = hotKey.displayText
        globalHotKey = hotKey
    }

    func applyFocus(_ focusRule: FocusRule) {
        if let browser = browsers.first(where: { $0.id == focusRule.browserID }) {
            choose(browser)
            statusMessage = "\(focusRule.focus) Focus switched the default to \(browser.name)."
        }
    }

    func runShortcutAction(named action: String) {
        statusMessage = "Shortcuts action '\(action)' ran locally."
    }

    func icon(for browser: Browser) -> NSImage {
        guard let applicationURL = installedApplicationURL(for: browser) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }

        if let cached = iconCache[applicationURL.path] {
            return cached
        }

        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        image.size = NSSize(width: 32, height: 32)
        iconCache[applicationURL.path] = image
        return image
    }

    private func notifyChanged() {
        guard !isLoadingPreferences else { return }
        savePreferences()
        onChange?()
    }

    // MARK: - Installed browser discovery

    /// Asks LaunchServices for every app that can open web pages and filters the
    /// result down to things that are plausibly browsers.
    ///
    /// LaunchServices happily reports apps that only claim `https` for deep links
    /// (terminals, chat apps, automation tools) and stale copies of real browsers
    /// (Playwright caches, updater staging folders). An app counts as a browser
    /// when it handles `http`, `https` *and* `public.html`, and lives somewhere a
    /// user would actually launch it from.
    nonisolated static func scanInstalledBrowsers() -> [InstalledBrowserApp] {
        let workspace = NSWorkspace.shared
        guard
            let httpsURL = URL(string: "https://example.com"),
            let httpURL = URL(string: "http://example.com")
        else { return [] }

        func bundleIdentifiers(_ urls: [URL]) -> Set<String> {
            Set(urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
        }

        let httpsHandlers = workspace.urlsForApplications(toOpen: httpsURL)
        let httpHandlerIDs = bundleIdentifiers(workspace.urlsForApplications(toOpen: httpURL))
        let htmlHandlerIDs = bundleIdentifiers(workspace.urlsForApplications(toOpen: .html))
        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        // Group every copy LaunchServices knows about by bundle identifier.
        var candidatesByBundleID: [String: [URL]] = [:]
        var bundleIDOrder: [String] = []
        for url in httpsHandlers {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { continue }
            if candidatesByBundleID[bundleIdentifier] == nil {
                bundleIDOrder.append(bundleIdentifier)
            }
            candidatesByBundleID[bundleIdentifier, default: []].append(url)
        }

        return bundleIDOrder.compactMap { bundleIdentifier -> InstalledBrowserApp? in
            guard
                bundleIdentifier != ownBundleIdentifier,
                httpHandlerIDs.contains(bundleIdentifier),
                htmlHandlerIDs.contains(bundleIdentifier)
            else { return nil }

            // Prefer the copy LaunchServices would launch, but fall back to any
            // copy in a normal location if that one is a cache/updater copy.
            let preferred = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
            let candidates = (preferred.map { [$0] } ?? []) + (candidatesByBundleID[bundleIdentifier] ?? [])
            guard let url = candidates.first(where: { !isIncidentalAppLocation($0) }) else { return nil }

            return InstalledBrowserApp(
                bundleIdentifier: bundleIdentifier,
                url: url,
                name: displayName(for: url)
            )
        }
    }

    /// Paths where app bundles exist as implementation details of something else
    /// (test-runner caches, auto-updater staging, mounted disk images, the Trash).
    nonisolated private static func isIncidentalAppLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let incidentalFragments = [
            "/Library/Caches/",
            "/Library/Application Support/",
            "/Library/Developer/",
            "/.Trash/",
            "/private/var/folders/"
        ]
        if incidentalFragments.contains(where: path.contains) {
            return true
        }
        // Mounted disk images. Only as a prefix: Safari itself lives under
        // /System/Volumes/Preboot/Cryptexes/.
        if path.hasPrefix("/Volumes/") {
            return true
        }
        // Dot-directories such as ~/.cache or ~/.continue hold tool-managed copies.
        return url.pathComponents.contains { $0.hasPrefix(".") && $0.count > 1 }
    }

    /// Merge the latest installed-browser scan into `browsers`, keeping the user's
    /// ordering and visibility choices. Returns whether the list changed.
    @discardableResult
    func refreshInstalledBrowsers() -> Bool {
        let installed = Self.scanInstalledBrowsers()
        let installedBundleIDs = Set(installed.map(\.bundleIdentifier))

        var updated = browsers.compactMap { browser -> Browser? in
            let isInstalled = browser.bundleIdentifiers.contains(where: installedBundleIDs.contains)
            if isInstalled {
                // The scan now manages this one; it no longer needs to be persisted.
                var browser = browser
                browser.isCustom = false
                return browser
            }
            // Uninstalled scan results disappear; hand-added entries stay so the
            // user can see them (marked "Not installed") and remove them.
            return browser.isCustom ? browser : nil
        }

        for app in installed where !updated.contains(where: { $0.bundleIdentifiers.contains(app.bundleIdentifier) }) {
            let id = browserID(for: app.bundleIdentifier)
            updated.append(
                Browser(
                    id: id,
                    bundleIdentifiers: [app.bundleIdentifier],
                    name: app.name,
                    isVisible: !savedHiddenBrowserIDs.contains(id)
                )
            )
        }

        updated = sortedBySavedOrder(updated)

        guard updated != browsers else { return false }
        logger.info("refreshInstalledBrowsers: \(updated.count) browsers (\(installed.count) installed)")
        browsers = updated
        return true
    }

    // MARK: - Preferences

    /// Switchbar 1.0.x ran as a bare executable, so its preferences live in the
    /// `Switchbar` defaults domain. Once it ships as a bundle with a real bundle
    /// identifier, `UserDefaults.standard` points somewhere else; copy the old
    /// values over once so upgrading does not reset anything.
    private func migrateLegacyDefaultsIfNeeded() {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            bundleIdentifier != Self.legacyDefaultsDomain,
            !defaults.bool(forKey: DefaultsKey.migratedLegacyDefaults)
        else { return }

        defer { defaults.set(true, forKey: DefaultsKey.migratedLegacyDefaults) }

        guard let legacy = defaults.persistentDomain(forName: Self.legacyDefaultsDomain), !legacy.isEmpty else {
            return
        }

        var copied = 0
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        logger.info("Migrated \(copied) preference(s) from the legacy defaults domain")
    }

    private func loadPreferences() {
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }

        savedHiddenBrowserIDs = Set(defaults.stringArray(forKey: DefaultsKey.hiddenBrowserIDs) ?? [])
        savedBrowserOrder = defaults.stringArray(forKey: DefaultsKey.browserOrder) ?? []

        loadCustomBrowsers()
        refreshInstalledBrowsers()

        // Trust what macOS actually reports over what we last saved: the default
        // may have been changed in System Settings while Switchbar was not running.
        if let systemDefaultBrowserID = refreshSystemDefaultBrowser() {
            selectedBrowserID = systemDefaultBrowserID
            logger.info("loadPreferences: using system default=\(systemDefaultBrowserID, privacy: .public)")
        } else if let savedSelectedBrowserID = defaults.string(forKey: DefaultsKey.selectedBrowserID),
                  browsers.contains(where: { $0.id == savedSelectedBrowserID }) {
            selectedBrowserID = savedSelectedBrowserID
            logger.info("loadPreferences: using saved browser=\(savedSelectedBrowserID, privacy: .public)")
        } else if let first = menuBrowsers.first ?? browsers.first {
            selectedBrowserID = first.id
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
            globalHotKey = Self.defaultHotKey
        }

        if let selectedBrowser {
            statusMessage = systemDefaultBrowserName == selectedBrowser.name
                ? "\(selectedBrowser.name) is the current macOS default browser."
                : "\(selectedBrowser.name) is selected."
        }
        logger.info("loadPreferences: final selectedBrowserID=\(self.selectedBrowserID, privacy: .public), browsers=\(self.browsers.count)")

        preregisterBrowsers()
        setLoginItemEnabled(launchAtLogin)
    }

    private func preregisterBrowsers() {
        Task.detached { [browsers = self.browsers] in
            let lsregisterPath = LaunchServices.lsregisterPath
            for browser in browsers {
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifiers.first ?? "") else { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: lsregisterPath)
                process.arguments = ["-f", appURL.path]
                try? process.run()
                process.waitUntilExit()
            }
        }
    }

    private func savePreferences() {
        let presentIDs = Set(browsers.map(\.id))

        // Keep remembered state for browsers that are not in the list right now.
        savedHiddenBrowserIDs = savedHiddenBrowserIDs
            .subtracting(presentIDs)
            .union(browsers.filter { !$0.isVisible }.map(\.id))
        savedBrowserOrder = browsers.map(\.id) + savedBrowserOrder.filter { !presentIDs.contains($0) }

        defaults.set(selectedBrowserID, forKey: DefaultsKey.selectedBrowserID)
        defaults.set(savedHiddenBrowserIDs.sorted(), forKey: DefaultsKey.hiddenBrowserIDs)
        defaults.set(hidesMenuBarIcon, forKey: DefaultsKey.hidesMenuBarIcon)
        defaults.set(launchAtLogin, forKey: DefaultsKey.launchAtLogin)
        defaults.set(menuBarIconMode.rawValue, forKey: DefaultsKey.menuBarIconMode)
        defaults.set(globalShortcut, forKey: DefaultsKey.globalShortcut)
        if let data = try? JSONEncoder().encode(globalHotKey) {
            defaults.set(data, forKey: DefaultsKey.globalHotKey)
        }
        defaults.set(savedBrowserOrder, forKey: DefaultsKey.browserOrder)
        saveCustomBrowsers()
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
        statusMessage = "Switching to \(browser.name)..."
        Task.detached { [weak self, browserID = browser.id, browserName = browser.name, bundleIdentifier, applicationURL] in
            guard let self else { return }

            // Fast path: plist write + register + kill lsd
            let plistWriteOK = self.setDefaultBrowserPlistOnly(bundleIdentifier, applicationURL: applicationURL)
            guard plistWriteOK else {
                await MainActor.run {
                    self.isSwitchingDefaultBrowser = false
                    self.statusMessage = "Failed to write Launch Services preferences for \(browserName)."
                    self.processPendingSwitch()
                }
                return
            }

            // Verify if the fast path worked
            if self.verifyDefaultBrowser(bundleIdentifier: bundleIdentifier) {
                await MainActor.run {
                    self.logger.info("Fast path succeeded for \(browserName, privacy: .public)")
                    self.statusMessage = "\(browserName) is now the macOS default browser."
                    self.isSwitchingDefaultBrowser = false
                    self.processPendingSwitch()
                }
                return
            }

            // Fast path failed — start progress timer and run full rebuild
            await MainActor.run { [weak self] in
                self?.statusMessage = "Rebuilding Launch Services..."
                self?.startProgressTimer()
            }

            let rebuildOK = self.fullRebuildAfterPlistWrite()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stopProgressTimer()
                if rebuildOK {
                    let refreshedBrowserID = self.refreshSystemDefaultBrowser()
                    self.logger.info("After full rebuild: expected=\(browserID, privacy: .public), actual=\(refreshedBrowserID ?? "nil", privacy: .public)")
                    self.statusMessage = refreshedBrowserID == browserID
                        ? "\(browserName) is now the macOS default browser."
                        : "Launch Services was rebuilt, but macOS still reports \(self.systemDefaultBrowserName ?? "another browser")."
                } else {
                    self.setDefaultBrowserUsingPublicFallback(bundleIdentifier: bundleIdentifier, browserID: browserID, browserName: browserName)
                }
                self.isSwitchingDefaultBrowser = false
                self.processPendingSwitch()
            }
        }
    }

    private func processPendingSwitch() {
        if let pending = pendingBrowserSwitch {
            pendingBrowserSwitch = nil
            setSystemDefaultBrowser(pending)
        }
    }

    private func startProgressTimer() {
        switchStartTime = CFAbsoluteTimeGetCurrent()
        progressTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let start = self.switchStartTime {
                    let elapsed = Int(CFAbsoluteTimeGetCurrent() - start)
                    self.statusMessage = "Rebuilding Launch Services (\(elapsed)s)..."
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
        switchStartTime = nil
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

    private func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            logger.info("Login item \(enabled ? "registered" : "unregistered", privacy: .public)")
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
        }
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

            let killResult = runCommand("/usr/bin/killall", arguments: ["lsd"])
            logger.info("killall lsd result: status=\(killResult.status), output=\(killResult.output, privacy: .public)")

            // Fast path: plist write + register + kill lsd
            if verifyDefaultBrowser(bundleIdentifier: bundleIdentifier) {
                logger.info("Fast path succeeded: Launch Services picked up the change")
                return true
            }

            // Fast path failed — fall back to full rebuild
            logger.info("Fast path failed: falling back to full lsregister rebuild")
            let rescanResult = runCommand(
                LaunchServices.lsregisterPath,
                arguments: ["-gc", "-R", "-all", "user,system,local,network"]
            )
            logger.info("lsregister rebuild result: status=\(rescanResult.status), output=\(rescanResult.output, privacy: .public)")

            let killAfterRebuild = runCommand("/usr/bin/killall", arguments: ["lsd"])
            logger.info("killall lsd after rebuild: status=\(killAfterRebuild.status)")

            return rescanResult.status == 0 && (killAfterRebuild.status == 0 || killAfterRebuild.status == 1)
        } catch {
            logger.error("MacAdmins-style LaunchServices update failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated private func setDefaultBrowserPlistOnly(_ bundleIdentifier: String, applicationURL: URL) -> Bool {
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

            let killResult = runCommand("/usr/bin/killall", arguments: ["lsd"])
            logger.info("killall lsd result: status=\(killResult.status), output=\(killResult.output, privacy: .public)")

            return true
        } catch {
            logger.error("MacAdmins-style plist update failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated private func fullRebuildAfterPlistWrite() -> Bool {
        let rescanResult = runCommand(
            LaunchServices.lsregisterPath,
            arguments: ["-gc", "-R", "-all", "user,system,local,network"]
        )
        logger.info("lsregister rebuild result: status=\(rescanResult.status), output=\(rescanResult.output, privacy: .public)")

        let killAfterRebuild = runCommand("/usr/bin/killall", arguments: ["lsd"])
        logger.info("killall lsd after rebuild: status=\(killAfterRebuild.status)")

        return rescanResult.status == 0 && (killAfterRebuild.status == 0 || killAfterRebuild.status == 1)
    }

    nonisolated private func verifyDefaultBrowser(bundleIdentifier: String) -> Bool {
        guard let testURL = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
              let actualBundleID = Bundle(url: appURL)?.bundleIdentifier
        else {
            return false
        }
        return actualBundleID == bundleIdentifier
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

    /// Adopt whatever macOS reports as the default even if the scan filtered it
    /// out, so the menu never claims a different browser is the default.
    private func discoverBrowser(bundleIdentifier: String, applicationURL: URL) -> Browser? {
        if let existing = browserMatching(bundleIdentifier: bundleIdentifier) {
            return existing
        }

        let browser = Browser(
            id: browserID(for: bundleIdentifier),
            bundleIdentifiers: [bundleIdentifier],
            name: Self.displayName(for: applicationURL),
            isVisible: true,
            isCustom: true
        )

        browsers.append(browser)
        return browser
    }

    private func loadCustomBrowsers() {
        guard let data = defaults.data(forKey: DefaultsKey.discoveredBrowsers) else { return }

        let storedBrowsers = (try? JSONDecoder().decode([StoredBrowser].self, from: data)) ?? []
        for storedBrowser in storedBrowsers where browserMatching(bundleIdentifier: storedBrowser.bundleIdentifier) == nil {
            browsers.append(
                Browser(
                    id: storedBrowser.id,
                    bundleIdentifiers: [storedBrowser.bundleIdentifier],
                    name: storedBrowser.name,
                    isVisible: !savedHiddenBrowserIDs.contains(storedBrowser.id),
                    isCustom: true
                )
            )
        }
    }

    private func saveCustomBrowsers() {
        let storedBrowsers = browsers
            .filter(\.isCustom)
            .compactMap { browser -> StoredBrowser? in
                guard let bundleIdentifier = browser.bundleIdentifiers.first else { return nil }
                return StoredBrowser(id: browser.id, bundleIdentifier: bundleIdentifier, name: browser.name, shortcut: nil)
            }

        guard let data = try? JSONEncoder().encode(storedBrowsers) else { return }
        defaults.set(data, forKey: DefaultsKey.discoveredBrowsers)
    }

    /// Order by the user's saved order; browsers never seen before go to the end
    /// in scan order.
    private func sortedBySavedOrder(_ browsers: [Browser]) -> [Browser] {
        let orderIndex = Dictionary(
            savedBrowserOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return browsers.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = orderIndex[lhs.element.id] ?? Int.max
                let rhsRank = orderIndex[rhs.element.id] ?? Int.max
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)
    }

    private func browserID(for bundleIdentifier: String) -> String {
        if let legacyID = Self.legacyBrowserIDs[bundleIdentifier] {
            return legacyID
        }
        let sanitizedID = bundleIdentifier
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
        return "discovered-" + String(sanitizedID)
    }

    /// The name Finder shows for the app, e.g. "Google Chrome" or "Orion - Work".
    nonisolated static func displayName(for applicationURL: URL) -> String {
        let finderName = FileManager.default.displayName(atPath: applicationURL.path)
        if finderName.hasSuffix(".app") {
            return String(finderName.dropLast(4))
        }
        return finderName.isEmpty ? applicationURL.deletingPathExtension().lastPathComponent : finderName
    }
}
