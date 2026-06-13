import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: BrowserModel
    @State private var isConfiguringBrowsers = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsRow("Launch at login") {
                    Toggle("", isOn: $model.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider()

                SettingsRow("Show menu bar icon") {
                    Toggle("", isOn: Binding(
                        get: { model.showsMenuBarIcon },
                        set: { model.showsMenuBarIcon = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                Divider()

                SettingsRow("Menu bar icon") {
                    Picker("", selection: $model.menuBarIconMode) {
                        ForEach(MenuBarIconMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                }

                Divider()

                SettingsRow("Shown browsers") {
                    Button("Configure...") {
                        isConfiguringBrowsers = true
                    }
                }

                Divider()

                SettingsRow("Toggle menu") {
                    HotKeyRecorder(
                        shortcut: $model.globalShortcut,
                        onRecord: { model.setGlobalHotKey($0) }
                    )
                        .frame(width: 150, height: 28)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.16))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.025))
                    )
            )
            .padding(.horizontal, 28)
            .padding(.top, 16)

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Link("Inspired by Default Browser", destination: URL(string: "https://sindresorhus.com/default-browser#scripting")!)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .frame(width: 475, height: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isConfiguringBrowsers) {
            BrowserConfigurationSheet()
                .environmentObject(model)
        }
    }
}

private struct SettingsRow<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)

            Spacer()

            accessory
                .controlSize(.large)
        }
        .frame(height: 42)
    }
}

private struct BrowserConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: BrowserModel
    @State private var draggedBrowserID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shown Browsers")
                        .font(.headline)
                    Text("Drag rows to reorder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    addBrowser()
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            List {
                ForEach(Array(model.browsers.enumerated()), id: \.element.id) { index, browser in
                    HStack(spacing: 12) {
                        BrowserIcon(browser: browser, size: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(browser.name)
                            if model.installedApplicationURL(for: browser) == nil {
                                Text("Not installed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Button {
                                model.moveBrowser(id: browser.id, direction: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)

                            Button {
                                model.moveBrowser(id: browser.id, direction: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == model.browsers.count - 1)
                        }
                        .buttonStyle(.borderless)

                        Toggle("", isOn: Binding(
                            get: { browser.isVisible },
                            set: { _ in model.toggleVisibility(for: browser) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                    .onDrag {
                        draggedBrowserID = browser.id
                        return NSItemProvider(object: browser.id as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: BrowserDropDelegate(
                            targetBrowser: browser,
                            draggedBrowserID: $draggedBrowserID,
                            model: model
                        )
                    )
                }
                .onMove { offsets, destination in
                    model.moveBrowsers(from: offsets, to: destination)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 430, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func addBrowser() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            model.addBrowser(from: url)
        }
    }
}

private struct BrowserDropDelegate: DropDelegate {
    let targetBrowser: Browser
    @Binding var draggedBrowserID: String?
    let model: BrowserModel

    func dropEntered(info: DropInfo) {
        guard let draggedBrowserID, draggedBrowserID != targetBrowser.id else { return }

        withAnimation {
            model.moveBrowser(id: draggedBrowserID, to: targetBrowser.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedBrowserID = nil
        return true
    }
}

private struct BrowserIcon: View {
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
        if !nsView.isRecording {
            nsView.title = shortcut.isEmpty ? "Record Shortcut" : shortcut
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var onShortcutChanged: ((HotKey) -> Void)?
    private(set) var isRecording = false
    private var localMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = "Recording..."
        window?.makeFirstResponder(self)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func record(_ event: NSEvent) {
        guard event.keyCode != 53 else {
            stopRecording()
            title = "Record Shortcut"
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

    private func shortcutDescription(for event: NSEvent) -> String {
        var parts: [String] = []
        if event.modifierFlags.contains(.control) { parts.append("⌃") }
        if event.modifierFlags.contains(.option) { parts.append("⌥") }
        if event.modifierFlags.contains(.shift) { parts.append("⇧") }
        if event.modifierFlags.contains(.command) { parts.append("⌘") }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return (parts + [key]).joined(separator: " ")
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
