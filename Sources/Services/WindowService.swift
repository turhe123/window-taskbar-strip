import AppKit
import ApplicationServices

/// A single button on the strip: one standard window (or one app when Accessibility is denied).
struct WindowItem: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let appName: String
    let title: String
    let isMinimized: Bool
    let isFrontmost: Bool
}

/// Enumerates windows through the Accessibility API and performs raise/minimize/close/quit actions.
@MainActor
final class WindowService: ObservableObject {
    @Published private(set) var windows: [WindowItem] = []
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// Frame (global, top-left origin) of the frontmost window when it is in full screen.
    @Published private(set) var fullScreenRect: CGRect?

    private var elements: [String: AXUIElement] = [:]
    private var icons: [pid_t: NSImage] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: Timer?
    private var inFlight = false
    private var pending = false
    private let queue = DispatchQueue(label: "WindowService.refresh", qos: .userInitiated)

    func start() {
        // Cap every AX call so a hung app can never block us for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = image
        return image
    }

    // MARK: Refresh

    /// Snapshot apps on the main thread, query AX on a background queue, publish only real changes.
    func refresh() {
        if inFlight { pending = true; return }
        inFlight = true
        let isTrusted = AXIsProcessTrusted()
        let excluded = Prefs.excludedIDs
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID
                && !excluded.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "App", hidden: $0.isHidden) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        queue.async {
            let result = isTrusted ? Self.scanWindows(apps: apps, frontPID: frontPID)
                                   : Self.scanApps(apps: apps, frontPID: frontPID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(result, trusted: isTrusted, pids: Set(apps.map(\.pid)))
                self.inFlight = false
                if self.pending { self.pending = false; self.refresh() }
            }
        }
    }

    private struct ScanResult {
        var items: [WindowItem] = []
        var elements: [String: AXUIElement] = [:]
        var fullScreen: CGRect?
    }

    private func apply(_ result: ScanResult, trusted isTrusted: Bool, pids: Set<pid_t>) {
        if trusted != isTrusted { trusted = isTrusted }
        if windows != result.items { windows = result.items }
        if fullScreenRect != result.fullScreen { fullScreenRect = result.fullScreen }
        elements = result.elements
        icons = icons.filter { pids.contains($0.key) }
        if isTrusted { syncObservers(pids: pids) }
    }

    nonisolated private static func scanApps(apps: [(pid: pid_t, name: String, hidden: Bool)], frontPID: pid_t?) -> ScanResult {
        var result = ScanResult()
        result.items = apps.map {
            WindowItem(id: "app-\($0.pid)", pid: $0.pid, appName: $0.name, title: $0.name,
                       isMinimized: $0.hidden, isFrontmost: $0.pid == frontPID)
        }
        return result
    }

    nonisolated private static func scanWindows(apps: [(pid: pid_t, name: String, hidden: Bool)], frontPID: pid_t?) -> ScanResult {
        var result = ScanResult()
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            guard let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            let focused = app.pid == frontPID ? attribute(appElement, kAXFocusedWindowAttribute) : nil
            for window in windows {
                // Requiring the standard subrole skips palettes, sheets, helpers and our own panel.
                guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String else { continue }
                let title = attribute(window, kAXTitleAttribute) as? String ?? ""
                let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
                let isFocused = focused.map { CFEqual($0, window) } ?? false
                let id = "\(app.pid)-\(CFHash(window))"
                result.items.append(WindowItem(id: id, pid: app.pid, appName: app.name,
                                               title: title.isEmpty ? app.name : title,
                                               isMinimized: minimized || app.hidden, isFrontmost: isFocused && !minimized))
                result.elements[id] = window
                if isFocused, attribute(window, "AXFullScreen") as? Bool == true {
                    result.fullScreen = frame(of: window)
                }
            }
        }
        return result
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated private static func frame(of window: AXUIElement) -> CGRect? {
        guard let pos = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(unsafeBitCast(pos, to: AXValue.self), .cgPoint, &point)
        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    // MARK: AXObserver (instant updates; the timer remains the fallback)

    private func syncObservers(pids: Set<pid_t>) {
        for pid in observers.keys where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let service = Unmanaged<WindowService>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { service.refresh() }
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids where observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            for note in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXTitleChangedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverAddNotification(observer, appElement, note as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
    }

    // MARK: Actions

    /// Raises the window, or minimizes it if it is already frontmost. Returns false when the app did not respond.
    @discardableResult
    func toggle(_ item: WindowItem) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return false }
        defer { refreshSoon() }
        guard let window = elements[item.id] else {
            // Apps-only mode (no Accessibility): activate or hide the whole app.
            if item.isFrontmost { app.hide() } else { app.unhide(); app.activate() }
            return true
        }
        if item.isFrontmost {
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        }
        if item.isMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if app.isHidden { app.unhide() }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
        return raised == .success
    }

    func close(_ item: WindowItem) {
        defer { refreshSoon() }
        guard let window = elements[item.id] else {
            NSRunningApplication(processIdentifier: item.pid)?.hide()
            return
        }
        if let button = Self.attribute(window, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
        }
    }

    func quit(_ item: WindowItem) {
        NSRunningApplication(processIdentifier: item.pid)?.terminate()
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }
}
