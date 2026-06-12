import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: BrowserModel
    @State private var isConfiguringBrowsers = false
    @State private var isRecordingShortcut = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Default Browser Settings")
                .font(.system(size: 19, weight: .semibold))
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    WindowControls()
                }
                .padding(.top, 18)
                .padding(.horizontal, 18)

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
                    Button(isRecordingShortcut ? "Recording..." : "Record Shortcut") {
                        isRecordingShortcut.toggle()
                        model.globalShortcut = isRecordingShortcut ? "Recording..." : "⌥ Space"
                    }
                    .frame(width: 176)
                    .disabled(isRecordingShortcut)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.16))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.025))
                    )
            )
            .padding(.horizontal, 28)
            .padding(.top, 42)

            Spacer(minLength: 24)
        }
        .frame(width: 475, height: 315)
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
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            accessory
                .controlSize(.large)
        }
        .frame(height: 52)
    }
}

private struct WindowControls: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
            Circle()
                .fill(Color.white.opacity(0.16))
            Circle()
                .fill(Color.white.opacity(0.16))
        }
        .frame(width: 76, height: 18)
    }
}

private struct BrowserConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shown Browsers")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            List {
                ForEach(model.browsers) { browser in
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

                        Toggle("", isOn: Binding(
                            get: { browser.isVisible },
                            set: { _ in model.toggleVisibility(for: browser) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 360, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
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
