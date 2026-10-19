import AppKit
import Combine
import SwiftUI

/// Transient UI state shared by all strips: which button is hovered and which ones should shake.
@MainActor
final class StripModel: ObservableObject {
    @Published var hoveredID: String?
    @Published private(set) var shakeCounts: [String: Int] = [:]

    func shake(_ id: String) {
        withAnimation(.linear(duration: 0.4)) { shakeCounts[id, default: 0] += 1 }
    }
}

/// Borderless, non-activating panel that hosts one strip and never steals focus.
final class StripPanel: NSPanel {
    var revealed = true
    let targetScreen: NSScreen

    init(screen: NSScreen) {
        targetScreen = screen
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Creates one panel per chosen screen, positions it on the configured edge, and drives auto-hide,
/// full-screen hiding, middle-click handling and display-change rebuilds.
@MainActor
final class StripController {
    private let service: WindowService
    private let model: StripModel
    private var panels: [StripPanel] = []
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var signature = ""

    private var defaults: UserDefaults { .standard }
    private var edge: StripEdge { StripEdge(rawValue: defaults.string(forKey: Prefs.edge) ?? "") ?? .bottom }
    private var thickness: CGFloat { CGFloat(min(max(defaults.double(forKey: Prefs.thickness), 20), 80)) }
    private var autoHide: Bool { defaults.bool(forKey: Prefs.autoHide) }

    init(service: WindowService, model: StripModel) {
        self.service = service
        self.model = model
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildIfNeeded() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        service.$fullScreenRect
            .receive(on: RunLoop.main)
            .sink { [weak self] rect in self?.updateFullScreen(rect) }
            .store(in: &cancellables)
        installMonitors()
        rebuild()
    }

    private func currentSignature() -> String {
        [Prefs.enabled, Prefs.edge, Prefs.thickness, Prefs.autoHide, Prefs.allDisplays]
            .map { "\(defaults.object(forKey: $0) ?? "")" }.joined(separator: "|")
    }

    private func rebuildIfNeeded() {
        if currentSignature() != signature { rebuild() }
    }

    /// Tears down and recreates every panel (settings or display layout changed).
    func rebuild() {
        signature = currentSignature()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        guard defaults.bool(forKey: Prefs.enabled) else { return }
        let screens = defaults.bool(forKey: Prefs.allDisplays) ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let panel = StripPanel(screen: screen)
            let view = StripView(service: service, model: model, edge: edge, thickness: thickness)
            panel.contentView = NSHostingView(rootView: view)
            panel.revealed = !autoHide
            panel.setFrame(autoHide ? hiddenFrame(on: screen) : shownFrame(on: screen), display: true)
            panel.alphaValue = autoHide ? 0 : 1
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        updateFullScreen(service.fullScreenRect)
    }

    // MARK: Geometry

    /// Uses `visibleFrame` so the strip sits below the menu bar and beside the Dock instead of covering them.
    private func shownFrame(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame, t = thickness
        switch edge {
        case .bottom: return NSRect(x: v.minX, y: v.minY, width: v.width, height: t)
        case .top: return NSRect(x: v.minX, y: v.maxY - t, width: v.width, height: t)
        case .left: return NSRect(x: v.minX, y: v.minY, width: t, height: v.height)
        case .right: return NSRect(x: v.maxX - t, y: v.minY, width: t, height: v.height)
        }
    }

    private func hiddenFrame(on screen: NSScreen) -> NSRect {
        let f = shownFrame(on: screen), t = thickness
        switch edge {
        case .bottom: return f.offsetBy(dx: 0, dy: -t)
        case .top: return f.offsetBy(dx: 0, dy: t)
        case .left: return f.offsetBy(dx: -t, dy: 0)
        case .right: return f.offsetBy(dx: t, dy: 0)
        }
    }

    /// True when the pointer is touching the strip's edge of the given screen.
    private func pointerAtEdge(_ p: NSPoint, of screen: NSScreen) -> Bool {
        let f = screen.frame, v = screen.visibleFrame
        guard f.insetBy(dx: -1, dy: -1).contains(p) else { return false }
        switch edge {
        case .bottom: return p.y <= f.minY + 2
        case .top: return p.y >= v.maxY - 2
        case .left: return p.x <= f.minX + 2
        case .right: return p.x >= f.maxX - 2
        }
    }

    // MARK: Auto-hide & events

    private func installMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            Task { @MainActor in self?.handleMouse(NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            self?.handleMouse(NSEvent.mouseLocation)
            return event
        }) { monitors.append(local) }
        // Middle click on a button closes its window.
        if let middle = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] event in
            guard let self, event.window is StripPanel, event.buttonNumber == 2,
                  let id = self.model.hoveredID, let item = self.service.windows.first(where: { $0.id == id }) else { return event }
            self.service.close(item)
            return nil
        }) { monitors.append(middle) }
    }

    private func handleMouse(_ point: NSPoint) {
        guard autoHide else { return }
        for panel in panels where panel.isVisible {
            if !panel.revealed, pointerAtEdge(point, of: panel.targetScreen) {
                setRevealed(true, panel: panel)
            } else if panel.revealed, !panel.frame.insetBy(dx: -12, dy: -12).contains(point) {
                setRevealed(false, panel: panel)
            }
        }
    }

    private func setRevealed(_ revealed: Bool, panel: StripPanel) {
        panel.revealed = revealed
        let target = revealed ? shownFrame(on: panel.targetScreen) : hiddenFrame(on: panel.targetScreen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = revealed ? 1 : 0
        }
    }

    /// Hides the strip on any screen covered by a full-screen window (AX rect uses a top-left origin).
    private func updateFullScreen(_ rect: CGRect?) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for panel in panels {
            let f = panel.targetScreen.frame
            let flipped = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let covered = rect.map { flipped.intersection($0).width * flipped.intersection($0).height > f.width * f.height * 0.5 } ?? false
            if covered, panel.isVisible { panel.orderOut(nil) }
            if !covered, !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
}
