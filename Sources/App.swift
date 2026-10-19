import SwiftUI
import AppKit

/// Keys and defaults for every persisted setting (shared by `@AppStorage` and `UserDefaults`).
enum Prefs {
    static let enabled = "stripEnabled"
    static let edge = "stripEdge"
    static let thickness = "stripThickness"
    static let buttonWidth = "buttonWidth"
    static let autoHide = "autoHide"
    static let allDisplays = "allDisplays"
    static let showTitles = "showTitles"
    static let showClock = "showClock"
    static let excluded = "excludedApps"


    static func register() {
        UserDefaults.standard.register(defaults: [
            enabled: true, edge: StripEdge.bottom.rawValue, thickness: 32.0, buttonWidth: 180.0,
            autoHide: false, allDisplays: true, showTitles: true, showClock: true, excluded: ""
        ])
    }

    /// Excluded bundle identifiers, stored newline-separated.
    static var excludedIDs: Set<String> {
        let raw = UserDefaults.standard.string(forKey: excluded) ?? ""
        return Set(raw.split(separator: "\n").map(String.init))
    }

}

/// The screen edge the strip is docked to.
enum StripEdge: String, CaseIterable, Identifiable {
    case bottom, top, left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

/// Owns the long-lived services so both the menu bar scene and the panels share them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let service = WindowService()
    static let model = StripModel()
    private var controller: StripController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StripController(service: Self.service, model: Self.model)
        Self.service.start()
    }
}

/// App entry point: a menu bar extra plus a Settings window; the strip panels are AppKit-managed.
@main
struct WindowTaskbarStripApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() { Prefs.register() }

    var body: some Scene {
        MenuBarExtra("WindowTaskbarStrip", systemImage: "dock.rectangle") {
            MenuContent(service: AppDelegate.service)
        }
        Settings {
            SettingsView(service: AppDelegate.service)
        }
    }
}

/// Items shown in the menu bar extra's drop-down menu.
struct MenuContent: View {
    @ObservedObject var service: WindowService
    @AppStorage(Prefs.enabled) private var enabled = true
    @AppStorage(Prefs.edge) private var edge = StripEdge.bottom.rawValue
    @AppStorage(Prefs.autoHide) private var autoHide = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Show Strip", isOn: $enabled)
        Picker("Edge", selection: $edge) {
            ForEach(StripEdge.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Toggle("Auto-Hide", isOn: $autoHide)
        if !service.trusted {
            Divider()
            Button("Grant Window Access…") { service.requestAccess() }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Support / Donate ❤️") { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!) }
        Divider()
        Button("Quit WindowTaskbarStrip") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
