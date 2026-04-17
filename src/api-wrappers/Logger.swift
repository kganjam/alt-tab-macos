import SwiftyBeaver
import Foundation

class Logger {
    private static let logger = SwiftyBeaver.self
    static let flag = "--logs="
    static let longDateTimeFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    static let shortDateTimeFormat = "HH:mm:ss.SSS"

    static func initialize() {
        let console = ConsoleDestination()
        console.useTerminalColors = true
        configureDestination(console)
        console.format = "$C$D\(shortDateTimeFormat)$d $L$c $N.swift:$l $F $M"
        console.minLevel = decideLevel()
        logger.addDestination(console)
    }

    static func configureDestination(_ dest: BaseDestination) {
        dest.levelString.verbose = "VERB"
        dest.levelString.debug = "DEBG"
        dest.levelString.info = "INFO"
        dest.levelString.warning = "WARN"
        dest.levelString.error = "ERRO"
        dest.format = "$D\(shortDateTimeFormat)$d $L $N.swift:$l $F $M"
    }

    @discardableResult
    static func addDestination(_ dest: BaseDestination) -> Bool {
        logger.addDestination(dest)
    }

    @discardableResult
    static func removeDestination(_ dest: BaseDestination) -> Bool {
        logger.removeDestination(dest)
    }

    static func decideLevel() -> SwiftyBeaver.Level {
        if let level = (CommandLine.arguments.first { $0.starts(with: flag) })?.dropFirst(flag.count) {
            switch level {
                case "verbose": return .verbose
                case "debug": return .debug
                case "info": return .info
                case "warning": return .warning
                case "error": return .error
                default: break
            }
        }
        return .error
    }

    static func debug(_ message: @escaping () -> Any?, file: String = #file, function: String = #function, line: Int = #line, context: Any? = nil) {
        custom(level: .debug, file: file, function: function, line: line, context: context, message)
    }

    static func info(_ message: @escaping () -> Any?, file: String = #file, function: String = #function, line: Int = #line, context: Any? = nil) {
        custom(level: .info, file: file, function: function, line: line, context: context, message)
    }

    static func warning(_ message: @escaping () -> Any?, file: String = #file, function: String = #function, line: Int = #line, context: Any? = nil) {
        custom(level: .warning, file: file, function: function, line: line, context: context, message)
    }

    static func error(_ message: @escaping () -> Any?, file: String = #file, function: String = #function, line: Int = #line, context: Any? = nil) {
        custom(level: .error, file: file, function: function, line: line, context: context, message)
    }

    private static func custom(level: SwiftyBeaver.Level, file: String = #file, function: String = #function, line: Int = #line, context: Any? = nil, _ message: @escaping () -> Any?) {
        logger.custom(level: level, message: { "[\(threadName())] \(message())" }(), file: file, function: function, line: line, context: context)
    }


    private static func threadName() -> String {
        if Thread.isMainThread {
            return "main"
        } else if let name = Thread.current.name, !name.isEmpty {
            return name
        } else {
            let name = __dispatch_queue_get_label(nil)
            return String(cString: name, encoding: .utf8) ?? Thread.current.description
        }
    }
}

/// Custom diagnostic logging for debugging the Parallels Coherence focus
/// transitions. All output goes through NSLog so it appears in Console.app
/// (filter "AltTab") and in the launch redirect log at /tmp/alttab-run.log.
///
/// Toggle via UserDefaults:
///   defaults write com.lwouis.alt-tab-macos diagnosticsEnabled -bool true   # default
///   defaults write com.lwouis.alt-tab-macos diagnosticsEnabled -bool false  # silence
/// Continuous monitoring interval (ms):
///   defaults write com.lwouis.alt-tab-macos diagnosticsMonitorMs -int 500
///   defaults write com.lwouis.alt-tab-macos diagnosticsMonitorMs -int -1    # disable
class Diagnostics {
    private static let enabledKey = "diagnosticsEnabled"
    private static let monitorIntervalKey = "diagnosticsMonitorMs"
    private static var monitorTimer: Timer?
    private static let startTime = Date()

    static var enabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        NSLog("[DIAG %@] t+%.3fs %@", category, elapsed, message())
    }

    static func logTrackedRecency(_ label: String) {
        guard enabled else { return }
        let top = Windows.list
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            .prefix(8)
            .map { "\($0.lastFocusOrder):\(diagShortId($0))" }
            .joined(separator: " | ")
        log("RECENCY", "\(label): \(top)")
    }

    /// Overlays that dominate the top of CGWindowListCopyWindowInfo's
    /// return but aren't "real" app windows the user cares about.
    /// Filtered out so SYSZ actually shows the app z-order.
    private static let sysZOwnerBlocklist: Set<String> = [
        "Window Server", "Control Center", "Dock", "AltTab",
        "Notification Center", "SystemUIServer", "Spotlight",
        "Menubar", "Wallpaper", "CursorUIViewService",
        "LocalAuthenticationRemoteService",
    ]

    static func logSystemZOrder(_ label: String) {
        guard enabled else { return }
        // Query ALL windows (not just .optionOnScreenOnly) so we can see
        // targets that are on a different Space. Flag with [s=N] = on
        // active space indicator so we can tell if the target is even
        // visible on the current Space.
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        let filtered = info.filter { w in
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if sysZOwnerBlocklist.contains(owner) { return false }
            // Drop hidden/off-screen / zero-alpha overlays
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { return false }
            // Drop zero-size helper windows
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { return false }
            return true
        }
        let top = filtered.prefix(8).map { (w: [String: Any]) -> String in
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            let name = (w[kCGWindowName as String] as? String) ?? ""
            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            var actualLevel: CGWindowLevel = -1
            CGSGetWindowLevel(CGS_CONNECTION, CGWindowID(wid), &actualLevel)
            let short = name.isEmpty ? "" : ":\(name.prefix(22))"
            let vis = onScreen ? "on" : "OFF"
            return "[\(vis)] cLv\(layer)/aLv\(actualLevel) #\(wid) \(owner)\(short)"
        }
        log("SYSZ", "\(label): \(top.joined(separator: " || "))")
    }

    static func logFrontmostSignals(_ label: String) {
        guard enabled else { return }
        let nsWorkspace = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let atFront = Applications.frontmostPid
        // Query actual window-server level for the last-focused target.
        // If this stays at 0 despite our CGSSetWindowLevel(.., 3) call,
        // the pin isn't crossing process boundaries and z-order
        // enforcement relies solely on the CGSOrderWindow fight loop.
        var targetLevel: CGWindowLevel = -1
        if let wid = App.lastFocusedTargetWid {
            CGSGetWindowLevel(CGS_CONNECTION, wid, &targetLevel)
        }
        log("FRONT", "\(label): nsw=\(nsWorkspace?.description ?? "nil") atFront=\(atFront?.description ?? "nil") sessionWid=\(App.sessionSourceWid?.description ?? "nil") prevWid=\(App.previousSessionSourceWid?.description ?? "nil") lastTargetWid=\(App.lastFocusedTargetWid?.description ?? "nil") targetActualLevel=\(targetLevel)")
    }

    /// Permanent test overlay — a bright red box pinned at max level.
    /// If this stays above Parallels windows, the overlay approach works
    /// and the issue is positioning/timing. If Parallels draws OVER this,
    /// Parallels uses a compositor path that bypasses NSWindow levels.
    /// Toggle: defaults write com.lwouis.alt-tab-macos testOverlay -bool true/false
    static func showTestOverlay() {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .init(rawValue: 2147483631)
        panel.backgroundColor = .red.withAlphaComponent(0.8)
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = .canJoinAllSpaces
        panel.title = "AltTab Test Overlay"

        let label = NSTextField(labelWithString: "AltTab Test Overlay\nLevel: 2147483631\nShould stay on top of everything")
        label.frame = NSRect(x: 20, y: 60, width: 260, height: 80)
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.maximumNumberOfLines = 3
        panel.contentView?.addSubview(label)

        panel.orderFrontRegardless()
        log("TEST", "permanent test overlay shown at level 2147483631")
    }

    static func startContinuousMonitoring() {
        guard enabled else { return }
        // Default: OFF. Monitor only runs when explicitly enabled with
        // a positive interval via `diagnosticsMonitorMs`. The periodic
        // CGWindowListCopyWindowInfo call + string formatting was a
        // measurable contributor to main-thread stalls.
        let intervalMs = UserDefaults.standard.integer(forKey: monitorIntervalKey)
        guard intervalMs > 0 else {
            log("INIT", "continuous monitoring OFF (default). Enable: defaults write com.lwouis.alt-tab-macos diagnosticsMonitorMs -int 2000")
            return
        }
        stopContinuousMonitoring()
        // Run captures on a background queue so they don't block main.
        let workQueue = DispatchQueue.global(qos: .utility)
        monitorTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMs) / 1000.0, repeats: true) { _ in
            workQueue.async {
                logSystemZOrder("tick")
                DispatchQueue.main.async { logTrackedRecency("tick") }
            }
        }
        log("INIT", "continuous monitoring started, interval=\(intervalMs)ms")
    }

    static func stopContinuousMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private static func diagShortId(_ w: Window) -> String {
        let title = (w.title ?? "").prefix(18)
        let appName = w.application.localizedName ?? "?"
        let wid = w.cgWindowId.map { "#\($0)" } ?? "#nil"
        return "\(wid) \(appName):\(title)"
    }
}

/// Temporary overlay window that captures a target window's screenshot
/// and displays it as an AltTab-owned window at a high z-level. Since
/// WE own this window, CGSSetWindowLevel actually enforces the level
/// at the compositor — Parallels can't fight our z-order on our own
/// window.
///
/// Used during Par→mac transitions to "bridge" the visual gap while
/// Parallels' timer-driven re-activation settles (~1-1.5s). After the
/// overlay auto-dismisses, the real target window should be stable on
/// top (via counter-raise).
///
/// Toggle: defaults write com.lwouis.alt-tab-macos focusOverlayEnabled -bool false
/// Default: ON in this custom build.
class FocusOverlay {
    private static let enabledKey = "focusOverlayEnabled"
    private static var overlayWindow: NSPanel?
    private static let overlayLevel: NSWindow.Level = .init(rawValue: 2147483631) // just below cursor level — absolute max

    static var enabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Persistent overlay panel — created ONCE at launch (like the test
    /// overlay that proved it works), repositioned and shown/hidden per
    /// transition. Avoids the panel-creation gap that let OneNote flash.
    private static var persistentPanel: NSPanel?

    /// Call once at launch to create the persistent overlay panel.
    static func createPersistentOverlay() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = overlayLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = .canJoinAllSpaces
        let layerView = NSView()
        layerView.wantsLayer = true
        layerView.layer = CALayer()
        layerView.layer?.contentsGravity = .resizeAspectFill
        panel.contentView = layerView
        persistentPanel = panel
        Diagnostics.log("OVERLAY", "persistent panel created at level \(overlayLevel.rawValue)")
    }

    /// Cover multiple windows with separate overlay panels.
    /// Creates additional panels as needed (pool grows, never shrinks).
    private static var panelPool: [NSPanel] = []

    static func showOverMultiple(_ windows: [Window], duration: TimeInterval = 2.0) {
        guard enabled else { return }
        dismiss()
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var usedPanels: [NSPanel] = []

        for (idx, window) in windows.enumerated() {
            guard let position = window.position, let size = window.size else { continue }
            let frame = NSRect(x: position.x, y: screenHeight - position.y - size.height,
                               width: size.width, height: size.height)

            // Reuse from pool or create new
            let panel: NSPanel
            if idx < panelPool.count {
                panel = panelPool[idx]
            } else {
                let p = NSPanel(
                    contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                p.isFloatingPanel = true
                p.hidesOnDeactivate = false
                p.level = overlayLevel
                p.isOpaque = false
                p.hasShadow = false
                p.ignoresMouseEvents = true
                p.animationBehavior = .none
                p.collectionBehavior = .canJoinAllSpaces
                let layerView = NSView()
                layerView.wantsLayer = true
                layerView.layer = CALayer()
                layerView.layer?.contentsGravity = .resizeAspectFill
                p.contentView = layerView
                panelPool.append(p)
                panel = p
            }

            panel.setFrame(frame, display: false)
            panel.backgroundColor = .clear
            if let layerView = panel.contentView {
                layerView.frame = NSRect(origin: .zero, size: frame.size)
                layerView.layer?.contents = window.thumbnail
                layerView.layer?.frame = CGRect(origin: .zero, size: frame.size)
            }
            panel.orderFrontRegardless()
            usedPanels.append(panel)
        }
        CATransaction.flush()
        overlayWindow = usedPanels.first // track for dismiss
        Diagnostics.log("OVERLAY", "shown \(usedPanels.count) panels over \(windows.count) Par windows for \(duration)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            dismiss()
        }
    }

    /// Show single window overlay (kept for backwards compat)
    static func show(over window: Window, duration: TimeInterval = 2.0) {
        showOverMultiple([window], duration: duration)
    }

    static func dismiss() {
        for panel in panelPool {
            panel.orderOut(nil)
        }
        overlayWindow = nil
    }
}

/// custom destination to display logs in the debug window
class DebugWindowDestination: BaseDestination {
    var onNewEntry: ((SwiftyBeaver.Level, String) -> Void)?

    override var defaultHashValue: Int { return 2 }

    override init() {
        super.init()
        Logger.configureDestination(self)
        minLevel = .debug
    }

    override func send(_ level: SwiftyBeaver.Level, msg: String, thread: String,
                       file: String, function: String, line: Int, context: Any? = nil) -> String? {
        let formattedString = super.send(level, msg: msg, thread: thread,
                                         file: file, function: function, line: line, context: context)
        guard let formatted = formattedString else { return nil }
        let callback = onNewEntry
        DispatchQueue.main.async { callback?(level, formatted) }
        return formattedString
    }
}
