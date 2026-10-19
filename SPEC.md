# WindowTaskbarStrip — specification

**Tagline:** A slim always-visible taskbar strip listing every open window as a button you click to raise or minimize.

**Category:** Window Management

**Inspired by (paid):** uBar ($30 one-time)

**Frameworks:** SwiftUI, AppKit, ApplicationServices, CoreGraphics, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

(1) What the paid app does. uBar replaces the Dock with a Windows-style taskbar where each open window is a labeled button, at around 30 dollars one time, with a long-running user base of people who want to see window titles at a glance. Comparison articles on Dock replacements keep listing it as the leading paid option, which shows lasting demand. Our clean-room version is WindowTaskbarStrip, a lighter strip that sits at a screen edge without replacing the Dock.

(2) Feature set. A thin panel docked to the bottom, top, left or right of each chosen screen listing all open standard windows as buttons with app icon and title, grouped by app. Clicking a button raises the window, clicking the active window's button minimizes it. Middle click or a context menu offers Close Window and Quit App. A highlighted button marks the frontmost window. Minimized windows show dimmed. A clock label at the end is optional. The strip can reserve its space is not possible without the Dock, so instead it can be set to overlay and auto-hide: it slides in when the pointer touches that edge.

(3) UI spec. A MenuBarExtra for toggling the strip, choosing edge, and opening Settings and Quit. The strip is a borderless NSPanel at status window level spanning the screen edge, 32 points thick, with a SwiftUI HStack of buttons that truncate titles to a configurable width. Settings fields: edge picker, thickness stepper, button width slider, auto-hide toggle, show on all displays toggle, show window titles toggle, excluded apps list, and launch at login. Empty state when no windows exist shows only the clock and a faint label saying nothing open. Without Accessibility the strip lists apps only, and offers a banner to grant window access.

(4) Technical approach. Accessibility trust through AXIsProcessTrustedWithOptions. Refresh the window list every 0.5 seconds and on NSWorkspace launch, terminate and activation notifications, using per-app AX windows attributes for titles and minimized flags. Observe window creation and destruction through AXObserver where convenient, with the timer as a fallback. Raise with AXRaise and NSRunningApplication activate. Minimize by setting the AX minimized attribute. Place the panel using NSScreen frame, and for auto-hide use a global mouse moved monitor to detect the edge and animate the panel frame. Set collectionBehavior to canJoinAllSpaces so it follows Spaces. Persist settings with AppStorage and register launch at login with SMAppService. Approximately 480 lines.

(5) Edge cases. Apps with many windows can overflow the strip, so collapse to a scroll view with edge fades. Titles can change often, so diff by window identity to avoid flicker. Exclude our own panel and tiny helper windows by requiring the standard subrole. Handle full screen apps by hiding the strip while a full screen space is active. Avoid covering menu bar when set to top by offsetting below visibleFrame. Respond to display changes by rebuilding panels. If a window refuses to raise because its app is hung, show a brief shake animation instead of blocking.
