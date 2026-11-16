import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.canLaunchAtLogin)
            } footer: {
                if !model.canLaunchAtLogin {
                    Text("Available when running Switchbar.app. For the Homebrew binary, use `brew services start switchbar`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { model.showsMenuBarIcon },
                    set: { model.showsMenuBarIcon = $0 }
                ))

                Picker("Icon", selection: $model.menuBarIconMode) {
                    ForEach(MenuBarIconMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .disabled(model.hidesMenuBarIcon)

                LabeledContent("Open switcher") {
                    HotKeyRecorder(
                        shortcut: $model.globalShortcut,
                        onRecord: { model.setGlobalHotKey($0) }
                    )
                    .frame(width: 150, height: 24)
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                if model.hidesMenuBarIcon {
                    Text("With the icon hidden, press \(model.globalShortcut) to open the switcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Default Browser") {
                LabeledContent("Current default") {
                    if let browser = model.selectedBrowser {
                        HStack(spacing: 6) {
                            BrowserIcon(browser: browser, size: 18)
                            Text(browser.name)
                        }
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500, height: 400)
    }
}

// MARK: - Browsers

struct BrowsersSettingsView: View {
    @EnvironmentObject private var model: BrowserModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag to reorder, or drop an app here to add it. Numbers are the switcher's keyboard shortcuts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.browsers) { browser in
                        BrowserRow(
                            browser: browser,
                            shortcutNumber: shortcutNumber(for: browser),
                            isDefault: browser.id == model.selectedBrowserID,
                            isInstalled: model.installedApplicationURL(for: browser) != nil
                        )
                        .tag(browser.id)
                        .contextMenu { contextMenu(for: browser) }
                    }
                    .onMove { offsets, destination in
                        withAnimation(.snappy(duration: 0.2)) {
                            model.moveBrowsers(from: offsets, to: destination)
                        }
                    }
                    .onInsert(of: [.fileURL]) { index, providers in
                        insertApplications(from: providers, at: index)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand(perform: removeSelected)

                Divider()

                bottomBar
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
        }
        .padding(20)
        .frame(width: 500, height: 480)
        .onAppear { model.refresh() }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button {
                chooseApplication()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .help("Add an app…")

            Divider().frame(height: 16)

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 20)
            }
            .disabled(!canRemoveSelection)
            .help("Remove the selected app. Detected browsers can be hidden instead.")

            Spacer()

            Button {
                withAnimation { model.refresh() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 20)
            }
            .help("Scan for newly installed browsers")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func contextMenu(for browser: Browser) -> some View {
        let isInstalled = model.installedApplicationURL(for: browser) != nil
        let index = model.browsers.firstIndex(where: { $0.id == browser.id }) ?? 0

        Button("Make Default Browser") { model.choose(browser) }
            .disabled(!isInstalled || browser.id == model.selectedBrowserID)

        Button(browser.isVisible ? "Hide from Menu" : "Show in Menu") {
            model.toggleVisibility(for: browser)
        }

        Divider()

        Button("Move to Top") { model.moveBrowserToTop(id: browser.id) }
            .disabled(index == 0)
        Button("Move Up") { model.moveBrowser(id: browser.id, direction: -1) }
            .disabled(index == 0)
        Button("Move Down") { model.moveBrowser(id: browser.id, direction: 1) }
            .disabled(index == model.browsers.count - 1)

        Divider()

        Button("Show in Finder") {
            if let url = model.installedApplicationURL(for: browser) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(!isInstalled)

        if browser.isCustom {
            Button("Remove", role: .destructive) { model.removeBrowser(id: browser.id) }
        }
    }

    /// 1-based position in the switcher menu, matching its key equivalents.
    private func shortcutNumber(for browser: Browser) -> Int? {
        guard let index = model.menuBrowsers.firstIndex(where: { $0.id == browser.id }), index < 9 else {
            return nil
        }
        return index + 1
    }

    private var canRemoveSelection: Bool {
        guard let selection else { return false }
        return model.browsers.first(where: { $0.id == selection })?.isCustom == true
    }

    private func removeSelected() {
        guard canRemoveSelection, let selection else { return }
        model.removeBrowser(id: selection)
        self.selection = nil
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"

        if panel.runModal() == .OK {
            for url in panel.urls {
                model.addBrowser(from: url)
            }
        }
    }

    private func insertApplications(from providers: [NSItemProvider], at index: Int) {
        let model = model
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    withAnimation(.snappy(duration: 0.2)) {
                        model.addBrowser(from: url, at: index)
                    }
                }
            }
        }
    }
}

private struct BrowserRow: View {
    @EnvironmentObject private var model: BrowserModel

    let browser: Browser
    let shortcutNumber: Int?
    let isDefault: Bool
    let isInstalled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Show \(browser.name) in menu", isOn: Binding(
                get: { browser.isVisible },
                set: { _ in model.toggleVisibility(for: browser) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(browser.isVisible ? "Shown in the menu" : "Hidden from the menu")

            HStack(spacing: 10) {
                BrowserIcon(browser: browser, size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(browser.name)
                            .lineLimit(1)
                        if isDefault {
                            Text("Default")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if !isInstalled {
                        Text("Not installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(browser.isVisible && isInstalled ? 1 : 0.5)

            Spacer(minLength: 8)

            if let shortcutNumber, browser.isVisible {
                Text("\(shortcutNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .tertiaryLabelColor))
                    )
                    .help("Press \(shortcutNumber) in the switcher menu")
            }

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            AppIconImage(size: 96)
                .padding(.bottom, 12)

            Text("Switchbar")
                .font(.system(size: 22, weight: .semibold))

            HStack(spacing: 6) {
                Text(AppInfo.versionDescription)
                if let commit = AppInfo.commit {
                    Text("·")
                    Link(String(commit.prefix(7)), destination: AppInfo.repositoryURL.appending(path: "commit/\(commit)"))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 2)

            Text("Switch your default browser from the menu bar.")
                .font(.callout)
                .padding(.top, 12)

            HStack(spacing: 10) {
                Button("Check for Updates…") {
                    NSWorkspace.shared.open(AppInfo.releasesURL)
                }
                Button("GitHub") {
                    NSWorkspace.shared.open(AppInfo.repositoryURL)
                }
                Button("Report an Issue") {
                    NSWorkspace.shared.open(AppInfo.issuesURL)
                }
            }
            .controlSize(.regular)
            .padding(.top, 18)

            Spacer(minLength: 16)

            Text("Inspired by [Default Browser](https://sindresorhus.com/default-browser) by Sindre Sorhus.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Released under the MIT License.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .padding(.horizontal, 24)
        .frame(width: 500, height: 340)
    }
}

/// The real app icon when running from Switchbar.app, otherwise a SwiftUI
/// rendering of the same design (for `swift run` and the bare binary).
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.31, green: 0.56, blue: 1.0), Color(red: 0.36, green: 0.27, blue: 0.93)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .padding(size * 0.1)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.2), radius: size * 0.03, y: size * 0.02)
        }
    }
}

// MARK: - Shared

struct BrowserIcon: View {
    @EnvironmentObject private var model: BrowserModel

    let browser: Browser
    let size: CGFloat

    var body: some View {
        Image(nsImage: model.icon(for: browser))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var shortcut: String
    var onRecord: (HotKey) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.title = shortcut.isEmpty ? "Record Shortcut" : shortcut
        button.onShortcutChanged = { hotKey in
            shortcut = hotKey.displayText
            onRecord(hotKey)
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.currentShortcut = shortcut
        if !nsView.isRecording {
            nsView.title = shortcut.isEmpty ? "Record Shortcut" : shortcut
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onShortcutChanged: ((HotKey) -> Void)?
    var currentShortcut = ""
    private(set) var isRecording = false
    private var localMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        isRecording ? cancelRecording() : startRecording()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func startRecording() {
        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
        title = currentShortcut.isEmpty ? "Record Shortcut" : currentShortcut
    }

    private func stopRecording() {
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func record(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            cancelRecording()
            return
        }

        // A global shortcut without ⌘/⌥/⌃ would swallow ordinary typing
        // everywhere, so require one (function keys are fine on their own).
        let requiredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        let isFunctionKey = event.specialKey.map(Self.functionKeys.contains) ?? false
        guard !event.modifierFlags.intersection(requiredModifiers).isEmpty || isFunctionKey else {
            NSSound.beep()
            title = "Add ⌘, ⌥ or ⌃…"
            return
        }

        let shortcut = shortcutDescription(for: event)
        let hotKey = HotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers(for: event.modifierFlags),
            displayText: shortcut
        )
        onShortcutChanged?(hotKey)
        title = hotKey.displayText
        stopRecording()
    }

    private static let functionKeys: Set<NSEvent.SpecialKey> = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20
    ]

    private func shortcutDescription(for event: NSEvent) -> String {
        var parts: [String] = []
        if event.modifierFlags.contains(.control) { parts.append("⌃") }
        if event.modifierFlags.contains(.option) { parts.append("⌥") }
        if event.modifierFlags.contains(.shift) { parts.append("⇧") }
        if event.modifierFlags.contains(.command) { parts.append("⌘") }

        return (parts + [keyName(for: event)]).joined(separator: " ")
    }

    private func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default:
            if let specialKey = event.specialKey, let index = Self.functionKeys.sorted(by: { $0.rawValue < $1.rawValue }).firstIndex(of: specialKey) {
                "F\(index + 1)"
            } else {
                event.charactersIgnoringModifiers?.uppercased() ?? ""
            }
        }
    }

    private func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
