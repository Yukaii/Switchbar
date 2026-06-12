import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            TabView {
                GeneralPane()
                    .tabItem { Label("General", systemImage: "gearshape") }

                BrowsersPane()
                    .tabItem { Label("Browsers", systemImage: "globe") }

                AutomationPane()
                    .tabItem { Label("Automation", systemImage: "sparkles") }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(.regularMaterial)
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(
                    LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Switchbar")
                    .font(.system(size: 28, weight: .bold))
                Text("Switch browsers from the menu bar, keyboard, Focus, or Shortcuts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let systemDefaultBrowserName = model.systemDefaultBrowserName {
                    Text("macOS default: \(systemDefaultBrowserName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(24)
    }
}

private struct GeneralPane: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        Form {
            Picker("Default browser", selection: $model.selectedBrowserID) {
                ForEach(model.browsers) { browser in
                    Label {
                        Text(browser.name)
                    } icon: {
                        BrowserIcon(browser: browser, size: 16)
                    }
                        .tag(browser.id)
                }
            }
            .onChange(of: model.selectedBrowserID) { _, id in
                if let browser = model.browsers.first(where: { $0.id == id }) {
                    model.choose(browser)
                }
            }

            Toggle("Hide menu bar icon", isOn: $model.hidesMenuBarIcon)
            Toggle("Show the default browser's icon in the menu bar", isOn: $model.showsDefaultBrowserIcon)

            HStack {
                Text("macOS default browser")
                Spacer()
                Text(model.systemDefaultBrowserName ?? "Unknown")
                    .foregroundStyle(.secondary)
                Button("Refresh") {
                    _ = model.refreshSystemDefaultBrowser()
                }
            }

            HStack {
                Text("Keyboard shortcut")
                Spacer()
                TextField("Shortcut", text: $model.globalShortcut)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BrowsersPane: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose which browsers appear in the menu.")
                .foregroundStyle(.secondary)

            List {
                ForEach(model.browsers) { browser in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { browser.isVisible },
                            set: { _ in model.toggleVisibility(for: browser) }
                        ))
                        .labelsHidden()

                        BrowserIcon(browser: browser, size: 24)
                            .frame(width: 28)

                        Text(browser.name)
                        Spacer()
                        Text(browser.shortcut)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    .padding(.vertical, 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 12)
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

private struct AutomationPane: View {
    @EnvironmentObject private var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    automationRow("Set Browser", detail: "Receives a browser name and switches locally.")
                    automationRow("Get Browser", detail: "Returns \(model.selectedBrowser.name).")
                    Button("Run Set Browser") {
                        model.runShortcutAction(named: "Set Browser")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Focus filters") {
                VStack(spacing: 8) {
                    ForEach(model.focusRules) { rule in
                        HStack {
                            Text(rule.focus)
                            Spacer()
                            Text(model.browsers.first(where: { $0.id == rule.browserID })?.name ?? "Unknown")
                                .foregroundStyle(.secondary)
                            Button("Apply") {
                                model.applyFocus(rule)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private func automationRow(_ title: String, detail: String) -> some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
