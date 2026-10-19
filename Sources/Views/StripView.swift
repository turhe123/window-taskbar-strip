import SwiftUI
import AppKit

/// The strip's content: grouped window buttons in a fading scroll view, an access banner and a clock.
struct StripView: View {
    @ObservedObject var service: WindowService
    @ObservedObject var model: StripModel
    let edge: StripEdge
    let thickness: CGFloat
    @AppStorage(Prefs.buttonWidth) private var buttonWidth = 180.0
    @AppStorage(Prefs.showTitles) private var showTitles = true
    @AppStorage(Prefs.showClock) private var showClock = true

    private var vertical: Bool { edge.isVertical }
    private var stack: AnyLayout { vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4)) }

    /// Windows grouped by app, preserving the service's ordering.
    private var groups: [(pid: pid_t, items: [WindowItem])] {
        var result: [(pid: pid_t, items: [WindowItem])] = []
        for item in service.windows {
            if let index = result.firstIndex(where: { $0.pid == item.pid }) { result[index].items.append(item) }
            else { result.append((item.pid, [item])) }
        }
        return result
    }

    var body: some View {
        stack {
            if !service.trusted {
                Button { service.requestAccess() } label: {
                    Label(vertical ? "" : "Grant window access", systemImage: "lock.shield")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Allow Accessibility access to list and control individual windows")
            }
            if service.windows.isEmpty {
                Spacer()
                Text(vertical ? "—" : "Nothing open").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                    stack {
                        ForEach(Array(groups.enumerated()), id: \.element.pid) { index, group in
                            if index > 0 { Divider().frame(width: vertical ? nil : 1, height: vertical ? 1 : nil).padding(2) }
                            ForEach(group.items) { item in button(for: item) }
                        }
                    }
                    .padding(vertical ? .vertical : .horizontal, 10)
                }
                .mask(fadeMask)
            }
            if showClock { ClockView(compact: vertical) }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground())
    }

    private func button(for item: WindowItem) -> some View {
        WindowButton(item: item, icon: service.icon(for: item.pid), showTitle: showTitles && !vertical,
                     width: vertical ? thickness - 8 : (showTitles ? buttonWidth : thickness),
                     height: thickness - 8,
                     shakes: model.shakeCounts[item.id] ?? 0) {
            if !service.toggle(item) { model.shake(item.id) }
        }
        .onHover { inside in
            if inside { model.hoveredID = item.id } else if model.hoveredID == item.id { model.hoveredID = nil }
        }
        .contextMenu {
            Button(item.isFrontmost ? "Minimize" : "Raise") { service.toggle(item) }
            Button("Close Window") { service.close(item) }
            Divider()
            Button("Quit \(item.appName)") { service.quit(item) }
        }
    }

    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                               .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                       startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
    }
}

/// One window button: icon + truncated title, highlighted when frontmost and dimmed when minimized.
struct WindowButton: View {
    let item: WindowItem
    let icon: NSImage?
    let showTitle: Bool
    let width: CGFloat
    let height: CGFloat
    let shakes: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                if showTitle {
                    Text(item.title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, showTitle ? 6 : 0)
            .frame(width: max(width, 20), height: max(height, 16))
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(item.isFrontmost ? Color.accentColor : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.isMinimized ? 0.45 : 1)
        .modifier(ShakeEffect(animatableData: CGFloat(shakes)))
        .onHover { hovering = $0 }
        .help("\(item.appName) — \(item.title)")
    }

    private var fill: Color {
        if item.isFrontmost { return Color.accentColor.opacity(0.35) }
        return Color.primary.opacity(hovering ? 0.14 : 0.06)
    }
}

/// Horizontal shake used when a window's app does not respond to a raise request.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// Clock label at the end of the strip.
struct ClockView: View {
    let compact: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.system(size: compact ? 10 : 12, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, compact ? 0 : 6)
        }
    }
}

/// Behind-window blur so the strip looks native over any wallpaper.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
