import SwiftUI
import AppKit
import ServiceManagement

/// Settings window: layout, behaviour, excluded apps, launch at login, permissions and support.
struct SettingsView: View {
    @ObservedObject var service: WindowService
    @AppStorage(Prefs.edge) private var edge = StripEdge.bottom.rawValue
    @AppStorage(Prefs.thickness) private var thickness = 32.0
    @AppStorage(Prefs.buttonWidth) private var buttonWidth = 180.0
    @AppStorage(Prefs.autoHide) private var autoHide = false
    @AppStorage(Prefs.allDisplays) private var allDisplays = true
    @AppStorage(Prefs.showTitles) private var showTitles = true
    @AppStorage(Prefs.showClock) private var showClock = true
    @AppStorage(Prefs.excluded) private var excludedRaw = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var excluded: [String] { excludedRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Form {
            Section("Strip") {
                Picker("Edge", selection: $edge) {
                    ForEach(StripEdge.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Stepper("Thickness: \(Int(thickness)) pt", value: $thickness, in: 24...64, step: 2)
                LabeledContent("Button width: \(Int(buttonWidth)) pt") {
                    Slider(value: $buttonWidth, in: 80...320, step: 10)
                }
                Toggle("Show window titles", isOn: $showTitles)
                Toggle("Show clock", isOn: $showClock)
            }
            Section("Behaviour") {
                Toggle("Auto-hide (slides in when the pointer touches the edge)", isOn: $autoHide)
                Toggle("Show on all displays", isOn: $allDisplays)
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Excluded Apps") {
                if excluded.isEmpty { Text("No apps excluded").foregroundStyle(.secondary) }
                ForEach(excluded, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                        Spacer()
                        Button(role: .destructive) { remove(bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add Running App") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
            }
            Section("Permissions") {
                if service.trusted {
                    Label("Window access granted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Text("Without Accessibility access the strip can only list apps, not individual windows.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Grant Window Access…") { service.requestAccess() }
                }
            }
            Section {
                Button("Support / Donate ❤️") { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .filter { !excluded.contains($0.1) && $0.1 != Bundle.main.bundleIdentifier }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private func add(_ id: String) { excludedRaw = (excluded + [id]).joined(separator: "\n") }
    private func remove(_ id: String) { excludedRaw = excluded.filter { $0 != id }.joined(separator: "\n") }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not update login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
