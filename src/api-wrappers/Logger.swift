import SwiftyBeaver
import Foundation
import ScreenCaptureKit
import AVFoundation

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
///
/// Log level (overrides finer than enabled boolean). Each [DIAG <CAT>] line
/// has a category-defined required level; lines below the active min-level
/// are dropped before the message is even formatted (closures unevaluated):
///   off      — fully silent. Equivalent to diagnosticsEnabled=false.
///   error    — only failures/unexpected outcomes.
///   warn     — adds anomalies the user might notice (CLICKMISROUTE,
///              FRONT_MISMATCH, TITLEMISS, AXTITLE failed, CLICKAFTER mismatch).
///   info     — adds normal-flow events (PANEL show/hide, KEY release,
///              MOUSE click, FOCUS, SESSION, GUARD, TITLE refresh). DEFAULT.
///   perf     — adds end-to-end switch timing breakdown (SWITCH phases,
///              REFRESH counters). Use when measuring latency.
///   trace    — adds z-order debugging (SYSZ, SAMEAPP, RECENCY, ZALIGN,
///              ZENFORCE, ZRESTORE, ZQUICK, SIBLINGSDEMOTE, FRONTMOSTSET,
///              AXEVENT, COUNTER, OVERLAY, XPROC). Use when chasing
///              focus/z-order regressions.
///   verbose  — everything (PROFILER, WINSIDE, API, CTAP, INIT).
/// Set via:
///   defaults write com.lwouis.alt-tab-macos diagnosticsLevel info
///   defaults write com.lwouis.alt-tab-macos diagnosticsLevel perf
///   defaults write com.lwouis.alt-tab-macos diagnosticsLevel trace
///   defaults write com.lwouis.alt-tab-macos diagnosticsBasicPerfOnly -bool true
///
/// Continuous monitoring interval (ms):
///   defaults write com.lwouis.alt-tab-macos diagnosticsMonitorMs -int 500
///   defaults write com.lwouis.alt-tab-macos diagnosticsMonitorMs -int -1    # disable
class Diagnostics {
    enum Level: Int, Comparable {
        case off = 0, error = 1, warn = 2, info = 3, perf = 4, trace = 5, verbose = 6
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        static func parse(_ s: String) -> Level? {
            switch s.lowercased() {
            case "off", "silent", "none": return .off
            case "error", "err": return .error
            case "warn", "warning": return .warn
            case "info": return .info
            case "perf", "timing": return .perf
            case "trace", "debug": return .trace
            case "verbose", "all": return .verbose
            default: return nil
            }
        }
    }

    private static let enabledKey = "diagnosticsEnabled"
    private static let levelKey = "diagnosticsLevel"
    private static let monitorIntervalKey = "diagnosticsMonitorMs"
    private static var monitorTimer: Timer?
    private static let startTime = Date()

    /// Master kill-switch retained for back-compat. `false` forces level to .off.
    /// Default: true (controlled by level instead).
    static var enabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Active minimum level. Reads UserDefaults each call; NSUserDefaults
    /// caches in-memory so the lookup is a dict probe, not a disk hit.
    static var minLevel: Level {
        if !enabled { return .off }
        if let s = UserDefaults.standard.string(forKey: levelKey),
           let lv = Level.parse(s) {
            return lv
        }
        return .info
    }

    /// Required level for each known category. Unknown categories default
    /// to `.info` so accidental new sites still appear in normal runs.
    private static let categoryLevels: [String: Level] = [
        // warn — anomalies worth surfacing without full debug spew
        "TITLEMISS": .warn,
        "FRONT_MISMATCH": .warn,
        "AXTITLE": .warn,
        "CLICKMISROUTE": .warn,
        "CLICKAFTER": .warn,
        "CAPTURE": .warn,
        // info — normal-flow events (default for unknown categories)
        "PANEL": .info,
        "KEY": .info,
        "KEYEVENT": .info,
        "FOCUS": .info,
        "MOUSE": .info,
        "CLICK": .info,
        "SESSION": .info,
        "INIT": .info,
        "MANUAL": .info,
        "HIDE": .info,
        "GUARD": .info,
        "TITLE": .info,
        // perf — switch timing & panel build counters
        "SWITCH": .perf,
        "REFRESH": .perf,
        "AXFOCUS": .perf,
        "LOGCOST": .perf,
        // trace — z-order/focus mechanics
        "AXPREWARM": .trace,
        "AXRAISE": .trace,
        "ZWAIT": .trace,
        "SYSZ": .trace,
        "RECENCY": .trace,
        "SAMEAPP": .trace,
        "PARMAC": .verbose,
        "ZALIGN": .verbose,
        "ZENFORCE": .trace,
        "ZRESTORE": .trace,
        "ZQUICK": .trace,
        "FRONTMOSTSET": .trace,
        "SIBLINGSDEMOTE": .trace,
        "FRONT": .trace,
        "AXEVENT": .trace,
        "COUNTER": .trace,
        "OVERLAY": .trace,
        "XPROC": .trace,
        "TEST": .trace,
        // verbose — high-volume / IPC chatter
        // (PROFILER is opt-in via runProfilerAtLaunch; surface its lines
        // at info so an automated profiling run is visible at default level.)
        "PROFILER": .info,
        "WINSIDE": .verbose,
        "API": .verbose,
        "CTAP": .verbose,
    ]
    private static let basicPerfCategories: Set<String> = ["SWITCH", "REFRESH", "AXFOCUS", "LOGCOST"]

    private static func categoryLevel(_ category: String) -> Level {
        return categoryLevels[category] ?? .info
    }

    private static let startTimeNs = DispatchTime.now().uptimeNanoseconds
    private static let logCostQueue = DispatchQueue(label: "Diagnostics.logCost")
    private static var logCostCount: UInt64 = 0
    private static var logCostTotalNs: UInt64 = 0
    private static var logCostFormatNs: UInt64 = 0
    private static var logCostNslogNs: UInt64 = 0
    private static var logCostMaxNs: UInt64 = 0
    private static var logCostLastReportNs: UInt64 = 0

    /// Returns true iff a `log(category, …)` for this category would emit.
    /// Use to gate expensive precomputation done outside `log()`'s autoclosure.
    static func shouldLog(_ category: String) -> Bool {
        shouldEmit(category)
    }

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        let baseNs = startTimeNs
        let logStartNs = DispatchTime.now().uptimeNanoseconds
        guard shouldEmit(category) else { return }
        let elapsedMs = Double(logStartNs >= baseNs ? logStartNs - baseNs : 0) / 1_000_000
        // NSLog/asl truncate at the first embedded newline, splitting
        // a single logical message across multiple log lines and
        // hiding everything that came after the \n. We saw exactly
        // this with Coherence-window titles containing internal
        // newlines. Strip line-break characters from the message
        // before logging.
        let raw = message()
        var sanitized = raw
        if raw.contains("\n") || raw.contains("\r") {
            sanitized = raw
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        let beforeNslogNs = DispatchTime.now().uptimeNanoseconds
        let line = "[DIAG \(category)] \(String(format: "t+%.3fms", elapsedMs)) tid=\(currentThreadId()) q=\(currentQueueLabel()) \(sanitized)"
        NSLog("%@", line as NSString)
        let endNs = DispatchTime.now().uptimeNanoseconds
        recordLogCost(nowNs: endNs, totalNs: endNs - logStartNs, formatNs: beforeNslogNs - logStartNs, nslogNs: endNs - beforeNslogNs)
    }

    private static func shouldEmit(_ category: String) -> Bool {
        let requiredLevel = categoryLevel(category)
        guard minLevel >= requiredLevel else { return false }
        guard RuntimeFlags.diagnosticsBasicPerfOnly else { return true }
        return requiredLevel <= .warn || basicPerfCategories.contains(category)
    }

    private static func currentThreadId() -> String {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return String(tid)
    }

    private static func currentQueueLabel() -> String {
        if Thread.isMainThread { return "main" }
        if let name = Thread.current.name, !name.isEmpty { return name }
        let label = __dispatch_queue_get_label(nil)
        return String(cString: label, encoding: .utf8) ?? "?"
    }

    private static func recordLogCost(nowNs: UInt64, totalNs: UInt64, formatNs: UInt64, nslogNs: UInt64) {
        logCostQueue.async {
            logCostCount += 1
            logCostTotalNs += totalNs
            logCostFormatNs += formatNs
            logCostNslogNs += nslogNs
            logCostMaxNs = max(logCostMaxNs, totalNs)
            reportLogCostIfNeeded(nowNs)
        }
    }

    private static func reportLogCostIfNeeded(_ nowNs: UInt64) {
        guard shouldLog("LOGCOST") else { return }
        let baseNs = startTimeNs
        let now = nowNs >= baseNs ? nowNs - baseNs : 0
        guard now - logCostLastReportNs >= 2_000_000_000 else { return }
        logCostLastReportNs = now
        let count = max(logCostCount, 1)
        let line = String(format: "[DIAG LOGCOST] t+%.3fms tid=%@ q=%@ count=%llu avg=%.1fus max=%.1fus formatAvg=%.1fus nslogAvg=%.1fus", Double(now) / 1_000_000, currentThreadId(), currentQueueLabel(), count, Double(logCostTotalNs) / Double(count) / 1000, Double(logCostMaxNs) / 1000, Double(logCostFormatNs) / Double(count) / 1000, Double(logCostNslogNs) / Double(count) / 1000)
        NSLog("%@", line as NSString)
    }

    // MARK: - Switch timing
    // End-to-end latency for an Alt-Tab "switch": from hotkey event to
    // target window focused. All times in milliseconds since `switchT0`.
    // Phases are recorded under the "SWITCH" category so they can be
    // grepped together. Concurrency: written from main thread (keyboard
    // events, App.focus*) and from BackgroundWork.accessibilityCommandsQueue
    // (Window.focus tail). CFAbsoluteTime reads/writes are atomic enough
    // for diagnostics; we don't care about a torn read once a switch.
    static var switchT0: CFAbsoluteTime = 0
    static var switchLastPhase: CFAbsoluteTime = 0
    static var switchContext: String = ""

    static func startSwitchTiming(_ context: String) {
        guard shouldLog("SWITCH") else { return }
        let now = CFAbsoluteTimeGetCurrent()
        switchT0 = now
        switchLastPhase = now
        switchContext = context
        log("SWITCH", "t0 [\(context)]")
    }

    static func markSwitchPhase(_ name: String, extra: String = "") {
        guard shouldLog("SWITCH") else { return }
        guard switchT0 > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let total = (now - switchT0) * 1000
        let delta = (now - switchLastPhase) * 1000
        switchLastPhase = now
        let suffix = extra.isEmpty ? "" : " \(extra)"
        log("SWITCH", String(format: "%@ +%.1fms (Δ%.1fms) [%@]%@", name, total, delta, switchContext, suffix))
    }

    static func logTrackedRecency(_ label: String) {
        guard shouldLog("RECENCY") else { return }
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
        // Gate on SAMEAPP too — that's the regression-detector branch
        // inside this function. If both SYSZ and SAMEAPP are below the
        // active level, the entire CGWindowListCopyWindowInfo + per-window
        // CGSGetWindowLevel scan is skipped.
        guard shouldLog("SYSZ") || shouldLog("SAMEAPP") else { return }
        // Use .optionOnScreenOnly — Apple only guarantees front-to-back
        // z-order for "OnScreen" options. Without it, ordering is undefined.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        let filtered = info.filter { w in
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if sysZOwnerBlocklist.contains(owner) { return false }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { return false }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { return false }
            return true
        }
        var idx = 0
        var ownerCounts: [String: Int] = [:]
        let top = filtered.prefix(8).map { (w: [String: Any]) -> String in
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            ownerCounts[owner, default: 0] += 1
            let name = (w[kCGWindowName as String] as? String) ?? ""
            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            var actualLevel: CGWindowLevel = -1
            CGSGetWindowLevel(CGS_CONNECTION, CGWindowID(wid), &actualLevel)
            let short = name.isEmpty ? "" : ":\(name.prefix(22))"
            let result = "z\(idx) Lv\(layer) #\(wid) \(owner)\(short)"
            idx += 1
            return result
        }
        log("SYSZ", "\(label): \(top.joined(separator: " || "))")
        // Surfaces the "all-windows-up" regression. AltTab must focus a
        // single window per app — if multiple windows of the same owner
        // appear in the top-8 z-order after a focus, _SLPSSetFrontProcess
        // brought the whole process forward instead of just the target.
        let multi = ownerCounts.filter { $0.value > 1 }
        if !multi.isEmpty {
            let summary = multi.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            log("SAMEAPP", "\(label): top8 has \(summary) (>1 window of same app at top — should be 1)")
        }
    }

    static func logFrontmostSignals(_ label: String) {
        guard shouldLog("FRONT") else { return }
        let nswApp = NSWorkspace.shared.frontmostApplication
        let nswPid = nswApp?.processIdentifier
        let atFront = Applications.frontmostPid
        // Query the system-canonical focused window: frontmost app's AX
        // focused window attribute → CGWindowID.
        var sysFocusedWid: CGWindowID = 0
        var sysFocusedName: String = "?"
        if let pid = nswPid {
            let appRef = AXUIElementCreateApplication(pid)
            var focusedValue: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
               let windowRef = focusedValue {
                var widValue: CGWindowID = 0
                if _AXUIElementGetWindow(windowRef as! AXUIElement, &widValue) == .success {
                    sysFocusedWid = widValue
                }
                var titleValue: AnyObject?
                if AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let title = titleValue as? String {
                    sysFocusedName = String(title.prefix(25))
                }
            }
        }
        var targetLevel: CGWindowLevel = -1
        if let wid = App.lastFocusedTargetWid {
            CGSGetWindowLevel(CGS_CONNECTION, wid, &targetLevel)
        }
        log("FRONT", "\(label): nsw=\(nswPid?.description ?? "nil")(\(nswApp?.localizedName ?? "?")) sysFocus=\(sysFocusedWid):\(sysFocusedName) atFront=\(atFront?.description ?? "nil") lastTargetWid=\(App.lastFocusedTargetWid?.description ?? "nil")")
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

    /// Sample the TRUE window z-order every 200ms for 5 seconds.
    /// Captures what's actually on top at the compositor level.
    /// Call after a focus transition to see the z-order fight.
    static func sampleZOrderOverTime(label: String, durationMs: Int = 5000, intervalMs: Int = 200) {
        // Gate on SYSZ — sampler exists solely to feed logSystemZOrder.
        // Below `trace` this returns immediately, saving N background
        // CGWindowListCopyWindowInfo calls per focus.
        guard shouldLog("SYSZ") else { return }
        let samples = durationMs / intervalMs
        for i in 0..<samples {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(i * intervalMs)) {
                logSystemZOrder("\(label) +\(i * intervalMs)ms")
            }
        }
    }

    /// Log which app is frontmost + which window is key, with timestamp.
    /// Lightweight — no CGWindowList call.
    static func logFrontmostQuick(_ label: String) {
        guard shouldLog("ZQUICK") else { return }
        let nsw = NSWorkspace.shared.frontmostApplication
        log("ZQUICK", "\(label): pid=\(nsw?.processIdentifier ?? 0) app=\(nsw?.bundleIdentifier ?? "?") frontPid=\(Applications.frontmostPid ?? 0)")
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
    /// Master toggle for overlay mode. Also controls background refresh.
    /// defaults write com.lwouis.alt-tab-macos overlayMode -bool true/false
    static var overlayModeEnabled: Bool {
        if UserDefaults.standard.object(forKey: "overlayMode") == nil { return false }
        return UserDefaults.standard.bool(forKey: "overlayMode")
    }

    private static let enabledKey = "focusOverlayEnabled"
    private static var overlayWindow: NSPanel?
    // Level 50: above Parallels (L3) but BELOW AltTab's switcher panel
    // (.popUpMenu = L101). This means the overlay can stay visible
    // DURING the switcher display — covering Parallels windows while
    // the switcher draws on top. No need to dismiss for switcher.
    private static let overlayLevel: NSWindow.Level = .init(rawValue: 50)

    static var enabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Persistent overlay panel — created ONCE at launch (like the test
    /// overlay that proved it works), repositioned and shown/hidden per
    /// transition. Avoids the panel-creation gap that let OneNote flash.
    private static var persistentPanel: NSPanel?

    /// Pre-captured full-resolution CVPixelBuffer cache (GPU-native IOSurface).
    /// Accessed only from main thread.
    static var preCaptureCache: [CGWindowID: CVPixelBuffer] = [:]

    /// Capture via ScreenCaptureKit at FULL retina resolution.
    /// Stores both CMSampleBuffer (for AVSampleBufferDisplayLayer)
    /// and CGImage fallback.
    /// Cached SCShareableContent to avoid re-enumerating all windows
    /// on each capture (~100-500ms per call). Refreshed every 5s.
    @available(macOS 14.0, *)
    private static var cachedContent: SCShareableContent?
    private static var contentCacheTime: CFAbsoluteTime = 0

    @available(macOS 14.0, *)
    private static func getContent() async throws -> SCShareableContent {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedContent, now - contentCacheTime < 5.0 {
            return cached
        }
        let content = try await SCShareableContent.current
        cachedContent = content
        contentCacheTime = now
        return content
    }

    @available(macOS 14.0, *)
    static func preCapture(wid: CGWindowID, position: CGPoint, size: CGSize) {
        Diagnostics.log("OVERLAY", "preCapture wid=\(wid)")
        guard RuntimeFlags.focusOverlayCaptureEnabled,
              overlayModeEnabled,
              ScreenRecordingPermission.status == .granted else { return }
        let t0 = CACurrentMediaTime()
        Task {
            do {
                let content = try await getContent()
                guard let scWindow = content.windows.first(where: { $0.windowID == wid }) else { return }
                let config = SCStreamConfiguration()
                let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
                config.width = Int(size.width * scale)
                config.height = Int(size.height * scale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                let ms = Int((CACurrentMediaTime() - t0) * 1000)
                // Store CVPixelBuffer directly — NO GPU→CPU readback.
                // IOSurface stays in VRAM. Display via CALayer.contents.
                if let pb = sampleBuffer.pixelBuffer() ?? sampleBuffer.imageBuffer {
                    let w = CVPixelBufferGetWidth(pb)
                    let h = CVPixelBufferGetHeight(pb)
                    // CVPixelBuffer isn't Sendable — wrap in nonisolated(unsafe)
                    nonisolated(unsafe) let safePb = pb
                    await MainActor.run {
                        preCaptureCache[wid] = safePb
                    }
                    Diagnostics.log("OVERLAY", "SC pre-captured wid=\(wid) \(w)x\(h) in \(ms)ms (GPU-native, no readback)")
                }
            } catch {
                Diagnostics.log("OVERLAY", "SC preCapture error: \(error)")
            }
        }
    }

    static func clearPreCaptureCache() {
        preCaptureCache.removeAll()
    }

    /// Background refresh loop: capture every window every ~5 seconds.
    /// Keeps all caches warm so there's never a cold 1-2s hit.
    /// Captures run sequentially to avoid window server lock contention.
    private static var refreshTimer: Timer?

    @available(macOS 14.0, *)
    static func startBackgroundRefresh() {
        guard overlayModeEnabled, ScreenRecordingPermission.status == .granted else { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            // Defensive re-gate: even after the timer was scheduled, the
            // user may have toggled overlay mode off via the menu. We
            // can't rely on stopBackgroundRefresh being called from
            // every code path that flips the flag — and we observed
            // 708MB RSS at idle that traced back to this Task running
            // when it shouldn't.
            guard overlayModeEnabled else { return }
            Task {
                guard overlayModeEnabled else { return }
                do {
                    let content = try await getContent()
                    // Only cache top 5 most-recently-used windows (not all 66!)
                    let windows = await MainActor.run {
                        Windows.list
                            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
                            .prefix(5)
                            .filter { $0.cgWindowId != nil && $0.position != nil && $0.size != nil }
                    }
                    // Clear stale entries
                    await MainActor.run { preCaptureCache.removeAll() }
                    for window in windows {
                        guard let wid = window.cgWindowId, let _ = window.position, let sz = window.size else { continue }
                        guard let scWindow = content.windows.first(where: { $0.windowID == wid }) else { continue }
                        let config = SCStreamConfiguration()
                        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
                        config.width = Int(sz.width * scale)
                        config.height = Int(sz.height * scale)
                        config.pixelFormat = kCVPixelFormatType_32BGRA
                        config.showsCursor = false
                        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                        if let pb = sample.pixelBuffer() ?? sample.imageBuffer {
                            nonisolated(unsafe) let safePb = pb
                            await MainActor.run { preCaptureCache[wid] = safePb }
                        }
                    }
                    Diagnostics.log("OVERLAY", "refreshed \(windows.count) windows")
                } catch {
                    Diagnostics.log("OVERLAY", "refresh error: \(error)")
                }
            }
        }
        Diagnostics.log("OVERLAY", "background refresh started (5s interval)")
    }

    /// Stop the periodic refresh and release any cached buffers.
    /// Called when overlay mode is toggled off — without this, the
    /// timer keeps running and Task captures keep populating
    /// preCaptureCache despite the gate, growing RSS unbounded.
    static func stopBackgroundRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let cleared = preCaptureCache.count
        preCaptureCache.removeAll()
        Diagnostics.log("OVERLAY", "background refresh stopped, cleared \(cleared) cached buffers")
    }

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

    private static var panelPool: [NSPanel] = []

    /// Show the TARGET window's content on the overlay at max level.
    /// This keeps Terminal visible regardless of what Parallels does.
    /// Converts IOSurface thumbnail to CGImage via CIContext (GPU path).
    static func showTarget(_ target: Window, duration: TimeInterval = 1.5) {
        Diagnostics.log("OVERLAY", "showTarget wid=\(target.cgWindowId ?? 0) duration=\(duration)s")
        guard enabled, let panel = persistentPanel else { return }
        guard let pos = target.position, let sz = target.size else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let screenHeight = screenFrame.height
        // Full screen panel with translucent red outside target area
        panel.setFrame(screenFrame, display: false)
        panel.backgroundColor = .clear

        let targetFrame = NSRect(
            x: pos.x - screenFrame.origin.x,
            y: screenHeight - pos.y - sz.height - screenFrame.origin.y,
            width: sz.width, height: sz.height)

        guard let containerView = panel.contentView else { return }
        containerView.frame = NSRect(origin: .zero, size: screenFrame.size)
        containerView.layer?.mask = nil
        containerView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        containerView.subviews.forEach { $0.removeFromSuperview() }
        let frame = targetFrame

        // Use pre-captured sharp image or thumbnail at target position.
        // CALayerHost didn't work (wid isn't a valid contextId,
        // CGSCopyWindowProperty("CtxID") returns nil on macOS 15+).
        // Display pre-captured CVPixelBuffer via IOSurface (full GPU path)
        var rendered = false
        if let wid = target.cgWindowId, let pb = preCaptureCache[wid],
           let surfaceRef = CVPixelBufferGetIOSurface(pb) {
            let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
            let w = IOSurfaceGetWidth(surface)
            let h = IOSurfaceGetHeight(surface)
            // Use a dedicated NSView with its own layer (sublayers didn't render IOSurface before)
            let surfaceView = NSView(frame: frame)
            surfaceView.wantsLayer = true
            surfaceView.layer = CALayer()
            surfaceView.layer?.contents = surface
            surfaceView.layer?.contentsGravity = .resizeAspectFill
            containerView.addSubview(surfaceView)
            rendered = true
            Diagnostics.log("OVERLAY", "GPU-native IOSurface \(w)x\(h) from SC capture")
        }
        if !rendered {
            Diagnostics.log("OVERLAY", "no pre-capture ready for wid=\(target.cgWindowId ?? 0)")
        }
        // DON'T clear cache — keep for next fast alt-tab

        panel.orderFrontRegardless()
        CATransaction.flush()
        overlayWindow = panel
        Diagnostics.log("OVERLAY", "shown target=\(target.debugId ?? "?") for \(duration)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            dismiss()
        }
    }

    static func showOverMultiple(_ windows: [Window], duration: TimeInterval = 2.0) {
        guard let first = windows.first else { return }
        showTarget(first, duration: duration)
    }

    static func show(over window: Window, duration: TimeInterval = 2.0) {
        showTarget(window, duration: duration)
    }

    static func dismiss() {
        Diagnostics.log("OVERLAY", "dismiss")
        persistentPanel?.orderOut(nil)
        persistentPanel?.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        persistentPanel?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        overlayWindow = nil
    }

    /// Dismiss overlay when switcher is about to show so it doesn't
    /// cover the TilesPanel.
    static func dismissForSwitcher() {
        if overlayWindow != nil {
            dismiss()
        }
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

/// Synthetic load generator for measuring focus-path success + latency.
/// Each attempt: optionally warms up a SOURCE window (so we control the
/// transition direction), then fires the measured focus via one of:
///   (1) tileClick: App.focusSelectedWindow(target) — single switch
///   (2) fastAltTab: focus an intermediate window, wait ~100ms, then
///       focus the real target. Stresses race conditions when the user
///       rapidly changes mind / cycles.
///
/// Transitions are weighted to over-sample Parallels-involving cases
/// (where the user reports flakiness):
///   parToPar=35%  parToMac=25%  macToPar=25%  macToMac=15%
///
/// At +50/100/200/500/1000/2000ms after each measured focus, samples
/// ground truth via NSWorkspace.frontmostApplication, AX
/// kAXFocusedWindow, and CGWindowListCopyWindowInfo. The +50/100ms
/// checkpoints expose perceptible-flicker bounces that ZENFORCE
/// recovers from before the longer-offset checkpoints.
///
/// Trigger:
///   defaults write com.lwouis.alt-tab-macos runProfilerAtLaunch -bool true
///   <restart AltTab>; profiler runs once, clears the flag.
class Profiler {
    static var isRunning = false
    private static var attempts: [Attempt] = []
    private static var startTime: CFAbsoluteTime = 0

    enum Mode: String { case tileClick, fastAltTab }
    enum Transition: String { case parToPar, parToMac, macToPar, macToMac }

    struct Attempt {
        let mode: Mode
        let transition: Transition
        let warmedSource: Bool
        let intermediateApp: String?
        let targetWid: CGWindowID
        let targetApp: String
        let targetTitle: String
        let isTargetParallels: Bool
        let requestTime: CFAbsoluteTime
        var checkpoints: [Checkpoint] = []
        var firstSuccessMs: Int?
        var stableAt2s: Bool = false
        var bouncedAtMs: [Int] = []
    }

    struct Checkpoint {
        let offsetMs: Int
        let frontmostPid: pid_t?
        let frontmostAppName: String
        let axFocusedWid: CGWindowID?
        let topZWid: CGWindowID?
        let topZApp: String
        let success: Bool
    }

    static func run(durationSeconds: TimeInterval = 60) {
        guard !isRunning else {
            Diagnostics.log("PROFILER", "already running, ignoring start")
            return
        }
        isRunning = true
        attempts = []
        startTime = CFAbsoluteTimeGetCurrent()
        let endTime = startTime + durationSeconds
        let par = eligibleTargets().filter { $0.isParallelsCoherenceWindow }.count
        let mac = eligibleTargets().count - par
        Diagnostics.log("PROFILER", "===== START — duration=\(Int(durationSeconds))s candidates par=\(par) mac=\(mac) =====")
        scheduleNext(endTime: endTime)
    }

    private static func scheduleNext(endTime: CFAbsoluteTime) {
        guard CFAbsoluteTimeGetCurrent() < endTime else {
            finish()
            return
        }
        DispatchQueue.main.async {
            performOne(endTime: endTime)
        }
    }

    private static func performOne(endTime: CFAbsoluteTime) {
        let transition = pickTransition()
        guard let plan = pickWindows(for: transition) else {
            Diagnostics.log("PROFILER", "no candidates for \(transition.rawValue); retrying in 0.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                scheduleNext(endTime: endTime)
            }
            return
        }
        let mode: Mode = Bool.random() ? .tileClick : .fastAltTab
        // Warmup: ensure the SOURCE window is currently frontmost so the
        // measured focus actually exercises this transition direction.
        let currentFront = topZOrderWindow().0
        let needsWarmup = plan.source.cgWindowId != currentFront
        let warmupDelayMs = needsWarmup ? 350 : 0
        if needsWarmup {
            Diagnostics.log("PROFILER", "warmup \(transition.rawValue): source=\(plan.source.application.localizedName ?? "?") wid=\(plan.source.cgWindowId ?? 0)")
            focusVia(plan.source)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(warmupDelayMs)) {
            runMeasured(mode: mode, transition: transition, plan: plan, warmedSource: needsWarmup, endTime: endTime)
        }
    }

    private static func runMeasured(mode: Mode, transition: Transition, plan: Plan, warmedSource: Bool, endTime: CFAbsoluteTime) {
        let target = plan.target
        let attempt = Attempt(
            mode: mode,
            transition: transition,
            warmedSource: warmedSource,
            intermediateApp: plan.intermediate?.application.localizedName,
            targetWid: target.cgWindowId!,
            targetApp: target.application.localizedName ?? "?",
            targetTitle: String((target.title ?? "").prefix(40)),
            isTargetParallels: target.isParallelsCoherenceWindow,
            requestTime: CFAbsoluteTimeGetCurrent()
        )
        attempts.append(attempt)
        let idx = attempts.count - 1
        Diagnostics.log("PROFILER", "#\(idx) start mode=\(mode.rawValue) trans=\(transition.rawValue) warmed=\(warmedSource) target=\(attempt.targetApp):wid=\(attempt.targetWid) title='\(attempt.targetTitle)'")
        switch mode {
        case .tileClick:
            focusVia(target)
            scheduleSamples(idx: idx, target: target, endTime: endTime)
        case .fastAltTab:
            // Rapid 2-step: focus intermediate, 100ms later focus the
            // real target. Simulates a user who alt-tabs to A, then
            // immediately changes mind and alt-tabs to B — exposes
            // races where ZENFORCE for A is still active when B fires.
            let inter = plan.intermediate ?? plan.source
            focusVia(inter)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                focusVia(target)
                scheduleSamples(idx: idx, target: target, endTime: endTime)
            }
        }
    }

    private static func focusVia(_ window: Window) {
        // Satisfy `guard appIsBeingUsed` in App.focusSelectedWindow.
        // The path itself calls hideUi(true) which resets it.
        App.appIsBeingUsed = true
        App.focusSelectedWindow(window)
    }

    private static func scheduleSamples(idx: Int, target: Window, endTime: CFAbsoluteTime) {
        // Sub-50ms checkpoints surface latency wins from focus-path
        // reorders. The 50ms→2000ms tail still measures stability so we
        // catch any z-order regressions from new fast paths.
        let offsets = [5, 10, 15, 20, 30, 40, 50, 100, 200, 500, 1000, 2000]
        for ms in offsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                let cp = sampleGroundTruth(target: target, offsetMs: ms)
                guard idx < attempts.count else { return }
                attempts[idx].checkpoints.append(cp)
                if cp.success && attempts[idx].firstSuccessMs == nil {
                    attempts[idx].firstSuccessMs = ms
                }
                if ms == offsets.last {
                    attempts[idx].stableAt2s = cp.success
                    // Bounce: any checkpoint that failed AFTER first-success.
                    // Useful even when stableAt2s=true — captures the brief
                    // intra-app sibling promotion that ZENFORCE corrects.
                    let firstOK = attempts[idx].firstSuccessMs ?? Int.max
                    let bouncedAt = attempts[idx].checkpoints
                        .filter { $0.offsetMs > firstOK && !$0.success }
                        .map { $0.offsetMs }
                    attempts[idx].bouncedAtMs = bouncedAt
                    // Failure log distinguishes "z0 wrong but AX right"
                    // (transient compositor-only blip; user usually doesn't
                    // notice) from "both wrong" (real input-routing failure).
                    let cps = attempts[idx].checkpoints.map { c -> String in
                        if c.success { return "\(c.offsetMs)=✓" }
                        let axRight = c.axFocusedWid == target.cgWindowId
                        let mark = axRight ? "z!ax✓" : "z!ax!"
                        return "\(c.offsetMs)=\(mark):\(c.topZApp.prefix(10))"
                    }.joined(separator: " ")
                    let bounceTag = bouncedAt.isEmpty ? "" : " bounced@\(bouncedAt.map { "\($0)" }.joined(separator: ","))"
                    Diagnostics.log("PROFILER", "#\(idx) result first=\(attempts[idx].firstSuccessMs.map { "\($0)ms" } ?? "never")\(bounceTag) | \(cps)")
                }
            }
        }
        // Next attempt: shorter wait if no warmup needed (~1.8s),
        // longer if we warmed up (~2.5s) — gives prior session
        // time to fully settle.
        let nextDelay = 2.0 + Double.random(in: 0...0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay) {
            scheduleNext(endTime: endTime)
        }
    }

    struct Plan {
        let source: Window
        let target: Window
        let intermediate: Window?
    }

    private static func pickWindows(for transition: Transition) -> Plan? {
        let candidates = eligibleTargets()
        let par = candidates.filter { $0.isParallelsCoherenceWindow }
        let mac = candidates.filter { !$0.isParallelsCoherenceWindow }
        let sourcePool: [Window]
        let targetPool: [Window]
        switch transition {
        case .parToPar:
            sourcePool = par
            targetPool = par
        case .parToMac:
            sourcePool = par
            targetPool = mac
        case .macToPar:
            sourcePool = mac
            targetPool = par
        case .macToMac:
            sourcePool = mac
            targetPool = mac
        }
        guard !sourcePool.isEmpty, !targetPool.isEmpty else { return nil }
        guard let source = sourcePool.randomElement() else { return nil }
        // Target must differ from source.
        let validTargets = targetPool.filter { $0.cgWindowId != source.cgWindowId }
        guard let target = validTargets.randomElement() else {
            // Pool too small for distinct source/target — only viable for
            // par→par/mac→mac with a single window. Bail out, caller retries.
            return nil
        }
        // For fastAltTab, pick an intermediate that's also in target pool
        // and distinct from source+target. Falls back to source if pool is
        // exhausted.
        let interPool = candidates.filter {
            $0.cgWindowId != source.cgWindowId && $0.cgWindowId != target.cgWindowId
        }
        let intermediate = interPool.randomElement()
        return Plan(source: source, target: target, intermediate: intermediate)
    }

    // Weighted sampler — even after H1 + finer checkpoints showed every
    // path passing at 5ms, the user explicitly cited Mac→Mac slowness, so
    // bias the sampler toward macToMac to build statistical confidence on
    // that path. Parallels-involving paths still get majority share since
    // they're the historical regression source.
    private static let transitionWeights: [(Transition, Int)] = [
        (.parToPar, 25), (.parToMac, 20), (.macToPar, 25), (.macToMac, 30),
    ]

    private static func pickTransition() -> Transition {
        let total = transitionWeights.map { $0.1 }.reduce(0, +)
        var r = Int.random(in: 0..<total)
        for (t, w) in transitionWeights {
            if r < w { return t }
            r -= w
        }
        return .macToMac
    }

    private static func eligibleTargets() -> [Window] {
        return Windows.list.filter { w in
            w.cgWindowId != nil
                && !w.isMinimized
                && !w.isHidden
                && w.application.bundleIdentifier != App.bundleIdentifier
                && w.shouldShowTheUser
                && (w.size?.width ?? 0) >= 200
                && (w.size?.height ?? 0) >= 80
        }
    }

    private static func sampleGroundTruth(target: Window, offsetMs: Int) -> Checkpoint {
        let nsApp = NSWorkspace.shared.frontmostApplication
        let frontPid = nsApp?.processIdentifier
        let frontName = nsApp?.localizedName ?? "?"
        var axFocusedWid: CGWindowID? = nil
        if let pid = frontPid {
            let appRef = AXUIElementCreateApplication(pid)
            var focusedValue: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
               let windowRef = focusedValue {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(windowRef as! AXUIElement, &wid) == .success {
                    axFocusedWid = wid
                }
            }
        }
        let (topWid, topApp) = topZOrderWindow()
        // Success = our target is ALSO at z0 or AX-focused. We don't
        // require both, since either signal alone reflects user-visible
        // success.
        let success = (topWid == target.cgWindowId) || (axFocusedWid == target.cgWindowId)
        return Checkpoint(
            offsetMs: offsetMs,
            frontmostPid: frontPid,
            frontmostAppName: frontName,
            axFocusedWid: axFocusedWid,
            topZWid: topWid,
            topZApp: topApp ?? "?",
            success: success
        )
    }

    private static func topZOrderWindow() -> (CGWindowID?, String?) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return (nil, nil) }
        let blocklist: Set<String> = [
            "Window Server", "Control Center", "Dock", "AltTab",
            "Notification Center", "SystemUIServer", "Spotlight",
            "Menubar", "Wallpaper", "CursorUIViewService",
            "LocalAuthenticationRemoteService",
        ]
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { continue }
            if let wid = w[kCGWindowNumber as String] as? Int {
                return (CGWindowID(wid), owner)
            }
        }
        return (nil, nil)
    }

    private static func finish() {
        let total = attempts.count
        guard total > 0 else {
            Diagnostics.log("PROFILER", "===== FINISHED — no attempts =====")
            isRunning = false
            return
        }
        let elapsed = Int(CFAbsoluteTimeGetCurrent() - startTime)
        Diagnostics.log("PROFILER", "===== SUMMARY (n=\(total), elapsed=\(elapsed)s) =====")
        for ms in [5, 10, 15, 20, 30, 40, 50, 100, 200, 500, 1000, 2000] {
            let s = attempts.filter { a in a.checkpoints.first(where: { $0.offsetMs == ms })?.success == true }.count
            Diagnostics.log("PROFILER", "success @ \(ms)ms: \(s)/\(total) (\(pct(s, total))%)")
        }
        let firstSuccesses = attempts.compactMap { $0.firstSuccessMs }
        if firstSuccesses.count >= 1 {
            let sorted = firstSuccesses.sorted()
            let avg = sorted.reduce(0, +) / sorted.count
            let p50 = sorted[sorted.count / 2]
            let p90Idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * 0.9)))
            let p90 = sorted[p90Idx]
            Diagnostics.log("PROFILER", "first-success ms (n=\(sorted.count)): avg=\(avg) p50=\(p50) p90=\(p90)")
        } else {
            Diagnostics.log("PROFILER", "first-success ms: NONE — every attempt missed at all checkpoints")
        }
        for mode in [Mode.tileClick, Mode.fastAltTab] {
            let m = attempts.filter { $0.mode == mode }
            guard !m.isEmpty else { continue }
            let s = m.filter { $0.stableAt2s }.count
            Diagnostics.log("PROFILER", "mode=\(mode.rawValue): \(s)/\(m.count) stable @ 2s (\(pct(s, m.count))%)")
        }
        for transition in [Transition.parToPar, .parToMac, .macToPar, .macToMac] {
            let t = attempts.filter { $0.transition == transition }
            guard !t.isEmpty else { continue }
            let s = t.filter { $0.stableAt2s }.count
            Diagnostics.log("PROFILER", "transition=\(transition.rawValue): \(s)/\(t.count) stable @ 2s (\(pct(s, t.count))%)")
        }
        var byApp: [String: (count: Int, stable: Int)] = [:]
        for a in attempts {
            var entry = byApp[a.targetApp] ?? (0, 0)
            entry.count += 1
            if a.stableAt2s { entry.stable += 1 }
            byApp[a.targetApp] = entry
        }
        Diagnostics.log("PROFILER", "per-app stable @ 2s:")
        for (app, stats) in byApp.sorted(by: { $0.key < $1.key }) {
            Diagnostics.log("PROFILER", "  \(app): \(stats.stable)/\(stats.count) (\(pct(stats.stable, stats.count))%)")
        }
        let failures = attempts.enumerated().filter { !$0.element.stableAt2s }
        if !failures.isEmpty {
            Diagnostics.log("PROFILER", "failures (\(failures.count)):")
            for (idx, a) in failures {
                let cps = a.checkpoints.map { c in
                    c.success ? "\(c.offsetMs)=✓" : "\(c.offsetMs)=top:\(c.topZApp)"
                }.joined(separator: " ")
                Diagnostics.log("PROFILER", "  #\(idx) \(a.mode.rawValue) trans=\(a.transition.rawValue) target='\(a.targetApp):\(a.targetTitle)' wid=\(a.targetWid) par=\(a.isTargetParallels) | \(cps)")
            }
        }
        // Recoverable-flicker stats: attempts that missed at +50/100ms
        // but ZENFORCE recovered by +200ms. Useful signal because the
        // user perceives the brief flicker even when the final state
        // is correct.
        let recoveredFromFlicker = attempts.filter { a in
            let f50 = a.checkpoints.first(where: { $0.offsetMs == 50 })?.success ?? true
            let f200 = a.checkpoints.first(where: { $0.offsetMs == 200 })?.success ?? false
            return !f50 && f200
        }.count
        Diagnostics.log("PROFILER", "flicker-then-recovered (50ms miss + 200ms hit): \(recoveredFromFlicker)/\(total) (\(pct(recoveredFromFlicker, total))%)")
        // Bounce stats: attempts that achieved first-success but had any
        // later failed checkpoint. Captures the intra-app sibling z-order
        // bounce that the +50/200ms pair misses (e.g. bounce at +100ms only).
        let bounced = attempts.filter { !$0.bouncedAtMs.isEmpty }
        if !bounced.isEmpty {
            Diagnostics.log("PROFILER", "post-success bounces: \(bounced.count)/\(total) (\(pct(bounced.count, total))%)")
            var bounceMsHist: [Int: Int] = [:]
            for a in bounced {
                for ms in a.bouncedAtMs { bounceMsHist[ms, default: 0] += 1 }
            }
            let hist = bounceMsHist.sorted { $0.key < $1.key }
                .map { "\($0.key)ms=\($0.value)" }.joined(separator: " ")
            Diagnostics.log("PROFILER", "bounce histogram: \(hist)")
        } else {
            Diagnostics.log("PROFILER", "post-success bounces: 0/\(total) (no z-order drift after first-success)")
        }
        Diagnostics.log("PROFILER", "===== END =====")
        isRunning = false
    }

    private static func pct(_ n: Int, _ d: Int) -> Int {
        guard d > 0 else { return 0 }
        return Int((Double(n) / Double(d) * 100).rounded())
    }
}

/// Winside: bridge to a tiny PowerShell TCP daemon running inside the
/// Parallels Windows 11 guest. Lets AltTab query and set the
/// guest-side foreground window directly via Win32 APIs (Get/SetForegroundWindow,
/// EnumWindows), bypassing the slow `prlctl exec` round-trip.
///
/// Wire protocol is line-based ASCII over TCP. See
/// `~/.alttab/winside-helper.ps1` for the server side. Status (IP+port)
/// is read from the JSON the helper writes to the shared folder, so we
/// don't have to re-`prlctl list -f` on every command.
///
/// Lifecycle:
///   - start(): if `winsideHelperEnabled` defaults key is set (default
///     ON) AND helper isn't already healthy, fire-and-forget
///     `prlctl exec` to launch it.
///   - stop(): TCP `EXIT` to the helper. Falls back to `prlctl exec
///     taskkill` if the EXIT command fails.
///   - isReady(): TCP `PING`/`PONG` round trip, ~10-50ms.
///   - queryForegroundAsync(): `FG` command, parses
///     `OK <hwnd> <pid> <title>` and logs as `[DIAG WINSIDE]`.
///   - setForegroundAsync(hwnd:): `SET <hwnd>`; logs result.
///
/// All commands run on a serial background queue so they don't block
/// the focus path. Defaults key `winsideHelperEnabled` controls
/// auto-start at app launch + menu toggle.
class Winside {
    private static let port: Int = 18765
    private static let defaultsEnabledKey = "winsideHelperEnabled"
    private static let helperScriptHostPath = "\(NSHomeDirectory())/.alttab/winside-helper.ps1"
    private static let helperScriptGuestPath = #"\\Mac\Home\.alttab\winside-helper.ps1"#
    // Tiny VBS launcher invoked via wscript.exe (GUI subsystem app, no
    // console window). It re-launches powershell with WScript.Shell.Run
    // intWindowStyle=0 (SW_HIDE), which means the spawned powershell
    // process never has a visible console — no flash, no minimize
    // animation. Direct `prlctl exec --current-user powershell` would
    // create a visible console host first and only hide it once
    // PowerShell processes -WindowStyle Hidden a few hundred ms in.
    private static let helperLauncherHostPath = "\(NSHomeDirectory())/.alttab/winside-launcher.vbs"
    private static let helperLauncherGuestPath = #"\\Mac\Home\.alttab\winside-launcher.vbs"#
    // Precise kill script. Lives in the same .alttab dir so it's always
    // available alongside the helper script. Targets ONLY powershell
    // processes whose command line contains the FULL UNC path to
    // winside-helper.ps1 — guarantees we don't kill anything else even
    // if a user happens to be running another script also named
    // winside-helper.ps1 from a different location.
    private static let helperKillerHostPath = "\(NSHomeDirectory())/.alttab/winside-kill.ps1"
    private static let helperKillerGuestPath = #"\\Mac\Home\.alttab\winside-kill.ps1"#
    private static let helperStatusHostPath = "\(NSHomeDirectory())/.alttab/winside-status.json"
    /// Native Windows GUI-subsystem launcher .exe. Spawns powershell with
    /// CREATE_NO_WINDOW (native flag, neither WSH nor WMI expose it) →
    /// helper has no console at all → Parallels Coherence has no window
    /// to flash. Compiled by helper.ps1 on first run via Add-Type
    /// -OutputType WindowsApplication. Once present, AltTab launches all
    /// subsequent helpers/kills through this .exe instead of the
    /// wscript+VBS+WMI(SW_HIDE) fallback (which has the flash).
    private static let helperLauncherExeHostPath = "\(NSHomeDirectory())/.alttab/winside-launcher.exe"
    private static let helperLauncherExeGuestPath = #"\\Mac\Home\.alttab\winside-launcher.exe"#
    private static let statusJsonPath = "\(NSHomeDirectory())/.alttab/winside-status.json"
    private static let vmName = "Windows 11"
    /// Serial queue so concurrent commands don't trample each other's
    /// stdin/stdout (we use one-shot Process invocations).
    private static let queue = DispatchQueue(label: "alttab.winside", qos: .utility)
    private static var lastKnownIp: String?

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsEnabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsEnabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsEnabledKey)
        Diagnostics.log("WINSIDE", "enabled set → \(enabled)")
        if enabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    /// Cache of the helper's IP from the status JSON. Tries up to N
    /// times across short sleeps (helper takes ~3-5s to start).
    private static func readStatusIp(retries: Int = 1) -> String? {
        for _ in 0..<retries {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: statusJsonPath)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ip = obj["ip"] as? String, !ip.isEmpty, ip != "0.0.0.0" {
                lastKnownIp = ip
                return ip
            }
            if retries > 1 { Thread.sleep(forTimeInterval: 0.5) }
        }
        return lastKnownIp
    }

    /// Persistent TCP socket file descriptor (-1 = no connection).
    /// All access goes through the serial queue, so no extra locking
    /// needed for the fd itself, but `connectIfNeeded` and `closeSocket`
    /// must run on `queue` too.
    private static var socketFd: Int32 = -1
    /// Counts consecutive sendOverSocket failures since last success.
    /// 3 in a row → declare the helper hung, kill it, re-launch.
    /// Real-world failure mode (observed 2026-05-01): helper
    /// process is alive in the guest but TCP listener is wedged
    /// after ~25 hours uptime. Without auto-restart, all SET calls
    /// silently no-op until AltTab is manually restarted.
    private static var consecutiveFailures: Int = 0
    private static let failureThreshold = 3
    /// Suppress recursive auto-restart attempts.
    private static var restartInProgress = false
    /// We only treat failures as "the helper hung" once we've actually
    /// seen one successful round-trip. Without this gate, the startup
    /// probe loop (which legitimately fails until the helper is up)
    /// instantly trips the restart logic and kills the helper we just
    /// launched.
    private static var everConnected = false

    private static func closeSocket(_ reason: String = "") {
        if socketFd >= 0 {
            close(socketFd)
            Diagnostics.log("WINSIDE", "socket closed\(reason.isEmpty ? "" : ": \(reason)")")
            socketFd = -1
        }
    }

    /// Open a persistent TCP socket to the helper. Returns true on
    /// success. Caller must be on `queue`. Idempotent: returns true
    /// quickly if socket is already open.
    private static func connectIfNeeded() -> Bool {
        if socketFd >= 0 { return true }
        guard let ip = readStatusIp() else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            Diagnostics.log("WINSIDE", "socket() failed: errno=\(errno)")
            return false
        }
        // SO_NOSIGPIPE: writing to a half-closed socket raises SIGPIPE
        // and kills the process with no crash report. We observed
        // this — AltTab vanished mid-alt-tab when the Winside helper
        // had hung, leaving no log past the focus's manualUpdate.
        // Mac doesn't have MSG_NOSIGNAL, so this is the per-socket
        // way to suppress.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // 5s read timeout. LIST can take 1-3s on a freshly-warmed
        // helper because PowerShell's first EnumWindows + JIT for
        // Add-Type imports is slow. With a 2s timeout we were
        // tripping on partial responses and dropping back to nc
        // fallback, where the parse only saw the first line and
        // declared "1 windows cached".
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // TCP_NODELAY for low latency (small commands).
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(ip)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            Diagnostics.log("WINSIDE", "connect(\(ip):\(port)) failed: errno=\(errno)")
            close(fd)
            return false
        }
        socketFd = fd
        Diagnostics.log("WINSIDE", "socket opened to \(ip):\(port) fd=\(fd)")
        return true
    }

    /// Send `cmd\n` over the persistent socket and read one line back.
    /// For multi-line responses (LIST), reads until "END\n" sentinel
    /// or terminator-pattern timeout.
    /// Returns nil on socket error; closes socket so next call reconnects.
    /// Multi-line aware via `expectMultiline` flag.
    private static func sendOverSocket(_ cmd: String, expectMultiline: Bool = false) -> String? {
        if !connectIfNeeded() { return nil }
        let payload = (cmd + "\n").data(using: .utf8)!
        let written = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            return Darwin.send(socketFd, raw.baseAddress, payload.count, 0)
        }
        if written != payload.count {
            closeSocket("send failed errno=\(errno)")
            return nil
        }
        // Read until we see a complete response. For most commands
        // that's one line. For LIST we keep reading until "END\n".
        var buf = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()
        while true {
            let n = recv(socketFd, &buf, buf.count, 0)
            if n <= 0 {
                closeSocket("recv n=\(n) errno=\(errno)")
                return nil
            }
            accumulated.append(contentsOf: buf[0..<n])
            if !expectMultiline {
                // First newline ends single-line responses.
                if accumulated.contains(0x0A) { break }
            } else {
                // LIST ends with a sentinel line "END\n" (or "END\r\n"
                // because the helper uses StreamWriter.WriteLine which
                // emits CRLF). Match it as a COMPLETE LINE — bracketed
                // by newlines on both sides — so a window title that
                // happens to contain literal "END" doesn't trigger a
                // false-positive end-of-response.
                if let s = String(data: accumulated, encoding: .utf8),
                   s.contains("\nEND\n") || s.contains("\nEND\r\n") || s.hasPrefix("END\n") || s.hasPrefix("END\r\n") {
                    break
                }
            }
            if accumulated.count > 1_000_000 {
                closeSocket("response too large")
                return nil
            }
        }
        let s = String(data: accumulated, encoding: .utf8) ?? ""
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n \u{FEFF}"))
    }

    /// Synchronous command. Tries persistent socket first; falls back to
    /// one-shot nc spawn if socket isn't available. Internal — caller
    /// must be on `queue`. Tracks consecutive failures and triggers
    /// helper restart when the threshold is hit.
    private static func sendCommandSync(_ cmd: String, timeoutSeconds: Int = 2) -> String? {
        let multiline = (cmd == "LIST")
        // Try the persistent socket first. ~50x faster than spawning nc.
        if let resp = sendOverSocket(cmd, expectMultiline: multiline) {
            consecutiveFailures = 0
            everConnected = true
            return resp
        }
        // Socket path failed (or no IP yet). Fall back to nc one-shot.
        guard let ip = readStatusIp() else {
            recordFailure(reason: "no status file")
            return nil
        }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "printf '%s\\n' '\(cmd)' | /usr/bin/nc -w \(timeoutSeconds) \(ip) \(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.launch()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            recordFailure(reason: "nc exit \(task.terminationStatus)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let resp = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n \u{FEFF}"))
        if resp == nil || resp?.isEmpty == true {
            recordFailure(reason: "empty nc response")
            return nil
        }
        consecutiveFailures = 0
        everConnected = true
        return resp
    }

    /// Bump the failure counter. After `failureThreshold` consecutive
    /// failures, declare the helper hung and re-launch it. Caller must
    /// be on `queue`.
    /// Only counts failures AFTER we've had at least one successful
    /// round-trip — startup probes shouldn't trigger restart.
    private static func recordFailure(reason: String) {
        guard everConnected else {
            // Pre-first-success: silently swallow. The startup probe
            // loop in startIfNeeded handles its own retry cadence.
            return
        }
        consecutiveFailures += 1
        Diagnostics.log("WINSIDE", "command failure #\(consecutiveFailures): \(reason)")
        if consecutiveFailures >= failureThreshold && !restartInProgress {
            restartInProgress = true
            Diagnostics.log("WINSIDE", "helper appears hung (\(consecutiveFailures) failures); killing + restarting")
            closeSocket("auto-restart")
            killHelperInGuest(reason: "auto-restart after \(consecutiveFailures) failures")
            consecutiveFailures = 0
            restartInProgress = false
            // Re-launch via the public path so probe + log fire normally.
            // Done from `queue.async` so we don't recurse on the queue.
            queue.async { startInternal() }
        }
    }

    /// Internal launcher (no enable-check, no probe). Used by both
    /// startIfNeeded and the auto-restart path.
    private static func startInternal() {
        ensureHelperScriptOnDisk()
        Diagnostics.log("WINSIDE", "startInternal: launching helper via prlctl exec")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            { () -> String in
                let useExe = FileManager.default.fileExists(atPath: helperLauncherExeHostPath)
                let prefix = useExe
                    ? "'\(helperLauncherExeGuestPath)'"
                    : "wscript.exe '\(helperLauncherGuestPath)'"
                return "nohup /usr/local/bin/prlctl exec '\(vmName)' --current-user \(prefix) '\(helperScriptGuestPath)' >/tmp/alttab-winside-launch.log 2>&1 &"
            }()
        ]
        task.launch()
        task.waitUntilExit()
    }

    /// True if helper responds to PING within `timeoutSeconds`.
    static func isReady(timeoutSeconds: Int = 2) -> Bool {
        return queue.sync {
            guard let resp = sendCommandSync("PING", timeoutSeconds: timeoutSeconds) else { return false }
            return resp.hasPrefix("PONG")
        }
    }

    /// Launch the helper inside the guest if not already healthy.
    /// Asynchronous; returns immediately.
    static func startIfNeeded() {
        guard isEnabled else {
            Diagnostics.log("WINSIDE", "startIfNeeded: disabled in prefs, skipping")
            return
        }
        queue.async {
            // Make sure ~/.alttab and the helper/launcher/kill scripts exist.
            ensureHelperScriptOnDisk()
            // AltTab.stop() always kills the helper on exit, so a status
            // file at startup means a previous AltTab crashed (orphaned
            // helper). Kill defensively. With the native .exe launcher,
            // both the kill and the new launch are flash-free.
            if FileManager.default.fileExists(atPath: helperStatusHostPath) {
                Diagnostics.log("WINSIDE", "startIfNeeded: orphaned status file at startup — killing prior helper")
                killHelperInGuest(reason: "orphan from prior AltTab crash")
            }
            Diagnostics.log("WINSIDE", "startIfNeeded: launching helper via prlctl exec")
            let task = Process()
            task.launchPath = "/bin/sh"
            // Fire-and-forget. The helper is a long-running PS process;
            // we don't waitUntilExit. `nohup` + `&` so the prlctl exec
            // call returns immediately.
            task.arguments = [
                "-c",
                { () -> String in
                let useExe = FileManager.default.fileExists(atPath: helperLauncherExeHostPath)
                let prefix = useExe
                    ? "'\(helperLauncherExeGuestPath)'"
                    : "wscript.exe '\(helperLauncherGuestPath)'"
                return "nohup /usr/local/bin/prlctl exec '\(vmName)' --current-user \(prefix) '\(helperScriptGuestPath)' >/tmp/alttab-winside-launch.log 2>&1 &"
            }()
            ]
            task.launch()
            task.waitUntilExit()  // wait only for the shell, not the prlctl
            // Probe up to 60s. Cold-start budget covers:
            //   prlctl exec connection (~5-10s)
            //   PowerShell -ExecutionPolicy Bypass cold start (~5-10s)
            //   Add-Type JIT compilation (~5-15s on first run)
            //   listener bind (~instant)
            // Subsequent runs are faster (warm caches), but we
            // intentionally don't tighten the budget: the cost of
            // waiting longer is just log noise; the cost of giving up
            // too early is the focus path can't use the helper at all.
            // Log a heartbeat every 5s so the user sees we're still
            // waiting.
            let totalSeconds = 60
            let pollIntervalSec = 0.5
            let polls = Int(Double(totalSeconds) / pollIntervalSec)
            var lastHeartbeat = 0
            for attempt in 1...polls {
                Thread.sleep(forTimeInterval: pollIntervalSec)
                if let resp = sendCommandSync("PING", timeoutSeconds: 1), resp.hasPrefix("PONG") {
                    let elapsedMs = Int(Double(attempt) * pollIntervalSec * 1000)
                    Diagnostics.log("WINSIDE", "startIfNeeded: helper ready after \(elapsedMs)ms at \(lastKnownIp ?? "?"):\(port)")
                    return
                }
                let elapsedSec = Int(Double(attempt) * pollIntervalSec)
                if elapsedSec >= lastHeartbeat + 5 {
                    Diagnostics.log("WINSIDE", "startIfNeeded: still waiting at \(elapsedSec)s (cold-start budget = \(totalSeconds)s)")
                    lastHeartbeat = elapsedSec
                }
            }
            Diagnostics.log("WINSIDE", "startIfNeeded: helper did NOT respond to PING within \(totalSeconds)s — see /tmp/alttab-winside-launch.log")
        }
    }

    /// Called from applicationWillTerminate. Always kills the helper
    /// in the guest so we never leave an orphaned PowerShell daemon
    /// behind. With the native .exe launcher in place, the next AltTab
    /// launch spawns a fresh helper without any visible window flash,
    /// so kill-on-exit costs nothing visually.
    static func stop() {
        queue.sync {
            if let resp = sendCommandSync("EXIT", timeoutSeconds: 2) {
                Diagnostics.log("WINSIDE", "stop: helper acknowledged → \(resp)")
                closeSocket("after EXIT ack")
                try? FileManager.default.removeItem(atPath: helperStatusHostPath)
                return
            }
            closeSocket("after EXIT failure")
            Diagnostics.log("WINSIDE", "stop: EXIT failed; falling back to precise kill")
            killHelperInGuest(reason: "EXIT-failed fallback", timeoutSeconds: 3)
        }
    }

    /// Async: query foreground window from guest. Logs result.
    /// Callback (optional) receives (hwnd, pid, title) on success or nil.
    static func queryForegroundAsync(label: String = "", callback: @escaping ((Int, Int, String)?) -> Void = { _ in }) {
        queue.async {
            guard let resp = sendCommandSync("FG", timeoutSeconds: 2) else {
                Diagnostics.log("WINSIDE", "FG \(label): no response (helper down?)")
                callback(nil)
                return
            }
            // Expected: "OK <hwnd> <pid> <title>"
            let parts = resp.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0] == "OK",
                  let hwnd = Int(parts[1]), let pid = Int(parts[2]) else {
                Diagnostics.log("WINSIDE", "FG \(label): bad response: \(resp.prefix(80))")
                callback(nil)
                return
            }
            let title = parts.count >= 4 ? parts[3] : ""
            Diagnostics.log("WINSIDE", "FG \(label): hwnd=\(hwnd) pid=\(pid) title='\(title.prefix(40))'")
            callback((hwnd, pid, title))
        }
    }

    /// Async: SetForegroundWindow on the given guest hwnd. Logs result.
    static func setForegroundAsync(hwnd: Int, label: String = "") {
        queue.async {
            guard let resp = sendCommandSync("SET \(hwnd)", timeoutSeconds: 2) else {
                Diagnostics.log("WINSIDE", "SET \(hwnd) \(label): no response (helper down?)")
                return
            }
            Diagnostics.log("WINSIDE", "SET \(hwnd) \(label): \(resp)")
        }
    }

    /// Replace all CR/LF with single spaces and collapse runs of
    /// whitespace, then trim ends. Coherence-side titles can contain
    /// internal newlines (multi-line AX titles); without this, both
    /// the cache key (built from LIST output) and the lookup needle
    /// (built from `Window.title`) end up with mismatched newline
    /// content and the dictionary lookup misses.
    private static func sanitizeTitle(_ raw: String) -> String {
        let noNewlines = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Collapse runs of whitespace to a single space.
        let parts = noNewlines.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Cache of guest title → hwnd, populated from LIST. Refreshed
    /// on demand via refreshHwndCacheIfStale.
    private static var hwndCache: [String: Int] = [:]
    private static var hwndCacheTime: CFAbsoluteTime = 0
    private static let hwndCacheStaleMs: Double = 1500

    /// Refresh the cache by issuing LIST. Synchronous — call from queue.
    /// Idempotent: skips if cache is fresh.
    private static func refreshHwndCacheIfStale() {
        let now = CFAbsoluteTimeGetCurrent()
        if !hwndCache.isEmpty && (now - hwndCacheTime) * 1000 < hwndCacheStaleMs {
            return
        }
        guard let resp = sendCommandSync("LIST", timeoutSeconds: 3) else {
            Diagnostics.log("WINSIDE", "LIST refresh: no response")
            return
        }
        var newCache: [String: Int] = [:]
        for line in resp.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "END" || trimmed.isEmpty { continue }
            // "<hwnd> <pid> <title>"
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3, let hwnd = Int(parts[0]) {
                newCache[sanitizeTitle(parts[2])] = hwnd
            }
        }
        if !newCache.isEmpty {
            hwndCache = newCache
            hwndCacheTime = now
            Diagnostics.log("WINSIDE", "LIST refresh: \(newCache.count) windows cached")
        }
    }

    /// Async: resolve hwnd from a Window's title, then SetForegroundWindow.
    /// Belt-and-suspenders intervention to fire after AltTab's macOS-side
    /// focus path completes — when SLPS+AX has succeeded but axFoc hasn't
    /// fully transferred from the source app, the Windows-side
    /// SetForegroundWindow is decisive (it goes through the OS's actual
    /// foreground-management path). No-op if the helper isn't running.
    /// Title-match strategy: exact match first, then prefix-match
    /// (handles cases where macOS-side title got truncated/altered).
    static func setForegroundForTitleAsync(_ title: String, label: String = "") {
        guard isEnabled else { return }
        // Parallels Coherence titles can contain INTERNAL newlines
        // (multi-line titles returned by AX), not just trailing ones.
        // `.trimmingCharacters(in: .whitespacesAndNewlines)` only strips
        // leading + trailing whitespace; internal `\n` survives. Replace
        // ALL line-break chars with a space so cache key + lookup match
        // and so NSLog doesn't truncate at an embedded newline.
        let needle = sanitizeTitle(title)
        guard !needle.isEmpty else { return }
        queue.async {
            refreshHwndCacheIfStale()
            // Exact match first.
            if let hwnd = hwndCache[needle] {
                guard let resp = sendCommandSync("SET \(hwnd)", timeoutSeconds: 2) else {
                    Diagnostics.log("WINSIDE", "SET \(hwnd) \(label) for title='\(needle.prefix(40))': no response")
                    return
                }
                Diagnostics.log("WINSIDE", "SET \(hwnd) \(label) (exact-match) title='\(needle.prefix(40))': \(resp)")
                return
            }
            // Prefix-match fallback: macOS sometimes truncates the
            // Coherence window title at ~30-50 chars; the guest still
            // has the full title. Match the longest cache key whose
            // prefix matches our title (or vice versa).
            let candidates = hwndCache.keys.filter { $0.hasPrefix(needle) || needle.hasPrefix($0) }
            if let bestTitle = candidates.max(by: { $0.count < $1.count }),
               let hwnd = hwndCache[bestTitle] {
                guard let resp = sendCommandSync("SET \(hwnd)", timeoutSeconds: 2) else {
                    Diagnostics.log("WINSIDE", "SET \(hwnd) \(label) for title-prefix='\(needle.prefix(40))': no response")
                    return
                }
                Diagnostics.log("WINSIDE", "SET \(hwnd) \(label) (prefix-match) title='\(needle.prefix(40))' → '\(bestTitle.prefix(40))': \(resp)")
                return
            }
            Diagnostics.log("WINSIDE", "SET \(label): no hwnd found for title='\(needle.prefix(40))' (cache size=\(hwndCache.count))")
        }
    }

    /// Idempotent: write the embedded PS script to disk if missing or
    /// out-of-date. Source string is bundled here so AltTab.app is
    /// self-contained — no manual placement needed.
    /// Returns true iff the helper script content on disk was changed
    /// (or written for the first time). Caller uses this to decide
    /// whether a running helper is stale and needs killing — if the
    /// script bytes are unchanged, an existing healthy helper is
    /// running our embedded version and we can re-use it without
    /// the kill+launch flash cycle.
    @discardableResult
    private static func ensureHelperScriptOnDisk() -> Bool {
        let dir = "\(NSHomeDirectory())/.alttab"
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var helperChanged = false
        let existingScript = (try? String(contentsOfFile: helperScriptHostPath, encoding: .utf8)) ?? ""
        if existingScript != helperScriptSource {
            helperChanged = true
            do {
                try helperScriptSource.write(toFile: helperScriptHostPath, atomically: true, encoding: .utf8)
                Diagnostics.log("WINSIDE", "wrote embedded helper script to \(helperScriptHostPath) (\(helperScriptSource.utf8.count) bytes)")
            } catch {
                Diagnostics.log("WINSIDE", "FAILED to write helper script: \(error)")
            }
        }
        let existingLauncher = (try? String(contentsOfFile: helperLauncherHostPath, encoding: .utf8)) ?? ""
        if existingLauncher != helperLauncherSource {
            do {
                try helperLauncherSource.write(toFile: helperLauncherHostPath, atomically: true, encoding: .utf8)
                Diagnostics.log("WINSIDE", "wrote embedded VBS launcher to \(helperLauncherHostPath) (\(helperLauncherSource.utf8.count) bytes)")
            } catch {
                Diagnostics.log("WINSIDE", "FAILED to write VBS launcher: \(error)")
            }
        }
        let existingKiller = (try? String(contentsOfFile: helperKillerHostPath, encoding: .utf8)) ?? ""
        if existingKiller != helperKillerSource {
            do {
                try helperKillerSource.write(toFile: helperKillerHostPath, atomically: true, encoding: .utf8)
                Diagnostics.log("WINSIDE", "wrote embedded kill script to \(helperKillerHostPath) (\(helperKillerSource.utf8.count) bytes)")
            } catch {
                Diagnostics.log("WINSIDE", "FAILED to write kill script: \(error)")
            }
        }
        return helperChanged
    }

    /// Run the embedded winside-kill.ps1 in the guest. Precisely targets
    /// powershell processes running our helper script (matched by full
    /// UNC path, not just filename). Invoked via the same hidden-launch
    /// path as the helper itself (wscript+VBS+WMI with SW_HIDE) so the
    /// kill script doesn't visibly flash a powershell console window
    /// on the user's screen via Parallels Coherence. The "wait" arg
    /// makes the VBS block until the kill script's powershell process
    /// exits.
    /// Bounded by `timeoutSeconds`. prlctl exec can take 10-20s; if the
    /// caller is shutdown-time-sensitive (applicationWillTerminate has
    /// ~5s before macOS forces SIGKILL), pass a short timeout and we'll
    /// terminate the wait early. The kill itself runs to completion in
    /// the guest regardless.
    private static func killHelperInGuest(reason: String, timeoutSeconds: Double = 15) {
        Diagnostics.log("WINSIDE", "killHelperInGuest (\(reason), timeout=\(timeoutSeconds)s): invoking winside-kill.ps1 (hidden) in '\(vmName)'")
        ensureHelperScriptOnDisk()
        let task = Process()
        task.launchPath = "/bin/sh"
        let useExe = FileManager.default.fileExists(atPath: helperLauncherExeHostPath)
        let prefix = useExe
            ? "'\(helperLauncherExeGuestPath)'"
            : "wscript.exe '\(helperLauncherGuestPath)'"
        task.arguments = [
            "-c",
            "/usr/local/bin/prlctl exec '\(vmName)' --current-user \(prefix) '\(helperKillerGuestPath)' wait 2>/tmp/alttab-winside-kill.log",
        ]
        task.launch()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            Diagnostics.log("WINSIDE", "killHelperInGuest: prlctl exec exceeded \(timeoutSeconds)s — terminating local wait (kill continues async in guest)")
            task.terminate()
        }
    }

    /// Generic VBS runner. Invoked via `wscript.exe` (GUI subsystem, no
    /// console). Uses WMI Win32_Process.Create with
    /// STARTUPINFO.wShowWindow=SW_HIDE so the powershell console is
    /// created already-hidden — no visible flash, unlike
    /// WScript.Shell.Run which hides AFTER creation.
    /// Note: WMI's CreateFlags does NOT support CREATE_NO_WINDOW
    /// (0x08000000) — only DEBUG_PROCESS, CREATE_SUSPENDED,
    /// CREATE_SHARED_WOW_VDM, CREATE_NEW_CONSOLE, CREATE_NEW_PROCESS_GROUP.
    /// Setting CREATE_NO_WINDOW returns ret=21 (Invalid Parameter).
    /// SW_HIDE in STARTUPINFO is the closest we can get from VBS.
    /// Usage: wscript winside-launcher.vbs <ps1-path> [wait]
    ///   <ps1-path>  Full UNC/local path to the .ps1 script
    ///   wait        Optional literal "wait" to block until the spawned
    ///               powershell exits (used for the kill script; the
    ///               helper launches async).
    private static let helperLauncherSource = #"""
    If WScript.Arguments.Count < 1 Then WScript.Quit 2
    Dim scriptPath, waitFlag
    scriptPath = WScript.Arguments(0)
    waitFlag = False
    ' VBScript And does NOT short-circuit; nested If avoids
    ' "Subscript out of range" when Arguments(1) doesn't exist.
    If WScript.Arguments.Count >= 2 Then
        If LCase(WScript.Arguments(1)) = "wait" Then waitFlag = True
    End If
    On Error Resume Next
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    Set su = wmi.Get("Win32_ProcessStartup").SpawnInstance_
    su.ShowWindow = 0
    Dim pid
    ret = wmi.Get("Win32_Process").Create("powershell -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", Null, su, pid)
    If ret <> 0 Then WScript.Quit ret
    If waitFlag Then
        Do
            Set procs = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE ProcessId=" & pid)
            If procs.Count = 0 Then Exit Do
            WScript.Sleep 100
        Loop
    End If
    WScript.Quit 0
    """#

    /// Precise kill: only powershell.exe / pwsh.exe processes whose
    /// command line contains the full UNC path to winside-helper.ps1.
    /// CommandLine.Contains() avoids the wildcard / quote escaping
    /// pitfalls of `-like '*...*'`. Uses Get-CimInstance (modern, faster)
    /// with Get-WmiObject fallback for legacy PowerShell. Also removes
    /// winside-status.json so a subsequent PING attempt from AltTab
    /// doesn't see a stale "helper is alive" signal.
    private static let helperKillerSource = #"""
    if (-not $env:WINSIDE_HIDDEN_RUN) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.WindowStyle = "Hidden"
        $psi.EnvironmentVariables["WINSIDE_HIDDEN_RUN"] = "1"
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        exit $proc.ExitCode
    }
    $expected = '\\Mac\Home\.alttab\winside-helper.ps1'
    $procs = $null
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction Stop
    } catch {
        $procs = Get-WmiObject Win32_Process
    }
    $procs |
        Where-Object { ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe') -and $_.CommandLine -and $_.CommandLine.Contains($expected) } |
        ForEach-Object {
            Write-Output ("kill pid=" + $_.ProcessId + " cmd=" + $_.CommandLine)
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Remove-Item '\\Mac\Home\.alttab\winside-status.json' -ErrorAction SilentlyContinue
    """#

    /// Embedded source of `winside-helper.ps1`. Updated whenever the
    /// guest-side daemon needs to change. Keep in sync with the file
    /// AltTab developers reference at runtime via `helperScriptHostPath`.
    /// Raw string (Swift `#"""..."""#`) so PowerShell `$` and `\` are
    /// literal.
    private static let helperScriptSource = #"""
## winside-helper.ps1 — TCP daemon for fast Windows-side window control.
## Started by AltTab via prlctl exec; talks to host over TCP.
##
## SELF-REHIDE: on first entry, re-spawn ourselves via
## [Diagnostics.Process]::Start with CreateNoWindow=$true. That uses the
## native CREATE_NO_WINDOW flag (0x08000000) which prevents Windows
## from allocating a console window at all — strictly stronger than
## SW_HIDE (which the launching layer uses). WMI's Win32_Process.Create
## doesn't expose CREATE_NO_WINDOW, so it can only hide an already-
## created console; that brief "hidden but exists" state is what
## Parallels Coherence flashes. Self-rehide eliminates the flash.
if (-not $env:WINSIDE_HIDDEN_RUN) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.WindowStyle = "Hidden"
    $psi.EnvironmentVariables["WINSIDE_HIDDEN_RUN"] = "1"
    [void][System.Diagnostics.Process]::Start($psi)
    exit 0
}

## Compile winside-launcher.exe on first run if not present. This .exe
## is GUI-subsystem (no console of its own) and uses CreateProcess via
## ProcessStartInfo.CreateNoWindow=true to spawn powershell with the
## native CREATE_NO_WINDOW flag — strictly stronger than wscript+VBS+
## WMI(SW_HIDE) which only hides an already-allocated console.
## We're running here in a CreateNoWindow process, so Add-Type's
## inline csc.exe invocation is also invisible (no Coherence flash).
$LauncherExe = '\\Mac\Home\.alttab\winside-launcher.exe'
if (-not (Test-Path $LauncherExe)) {
    try {
        Add-Type -OutputType WindowsApplication -OutputAssembly $LauncherExe -TypeDefinition @"
using System;
using System.Diagnostics;
public class L {
    public static int Main(string[] args) {
        if (args.Length < 1) return 1;
        var psi = new ProcessStartInfo {
            FileName = "powershell",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + args[0] + "\"",
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        if (args.Length >= 2 && args[1] == "wait") {
            var p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        }
        Process.Start(psi);
        return 0;
    }
}
"@
    } catch {}
}

## Wire protocol (line-based ASCII, \r\n or \n terminator):
##   PING                → PONG
##   FG                  → OK <hwnd> <pid> <title>
##   SET <hwnd>          → OK <0|1>   (1 = SetForegroundWindow returned true)
##   LIST                → multiple lines "<hwnd> <pid> <title>", terminated by END
##   EXIT                → OK BYE   (helper terminates after replying)
## Status JSON (so host can discover IP+port without prlctl exec each time):
##   \\Mac\Home\.alttab\winside-status.json
##   { "version": 1, "ip": "<guest-ip>", "port": 18765, "pid": <ps-pid>, "started": "<ISO8601>" }

$ErrorActionPreference = 'Stop'
$Port = 18765
$StatusPath = '\\Mac\Home\.alttab\winside-status.json'

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinSide {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
}
"@

function Get-PrimaryIPv4 {
    $candidates = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' }
    foreach ($c in $candidates) {
        $ip = $c.Address.ToString()
        if (-not $ip.StartsWith('169.254.')) { return $ip }
    }
    return '0.0.0.0'
}

function Write-Status {
    param([string]$Ip, [int]$Port, [int]$ProcessId)
    try {
        $obj = @{
            version = 1
            ip = $Ip
            port = $Port
            pid = $ProcessId
            started = (Get-Date).ToUniversalTime().ToString('o')
        }
        $json = $obj | ConvertTo-Json -Compress
        $dir = Split-Path -Parent $StatusPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($StatusPath, $json)
    } catch {}
}

function Get-FG-Line {
    $h = [WinSide]::GetForegroundWindow()
    $sb = New-Object Text.StringBuilder 512
    [WinSide]::GetWindowText($h, $sb, 512) | Out-Null
    $procId = 0
    [WinSide]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
    return "OK $($h.ToInt64()) $procId $($sb.ToString())"
}

function Do-SetForeground {
    param([Int64]$HwndInt)
    $h = New-Object IntPtr -ArgumentList $HwndInt
    if ([WinSide]::IsIconic($h)) {
        [WinSide]::ShowWindow($h, 9) | Out-Null
    }
    [WinSide]::BringWindowToTop($h) | Out-Null
    $r = [WinSide]::SetForegroundWindow($h)
    return "OK $([int]$r)"
}

function List-Windows {
    $lines = New-Object System.Collections.ArrayList
    $cb = {
        param([IntPtr]$h, [IntPtr]$lp)
        if ([WinSide]::IsWindowVisible($h)) {
            $sb = New-Object Text.StringBuilder 512
            [WinSide]::GetWindowText($h, $sb, 512) | Out-Null
            if ($sb.Length -gt 0) {
                $procId = 0
                [WinSide]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
                $lines.Add("$($h.ToInt64()) $procId $($sb.ToString())") | Out-Null
            }
        }
        return $true
    }
    [WinSide]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $lines
}

$ip = Get-PrimaryIPv4
$endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)
$listener = New-Object System.Net.Sockets.TcpListener -ArgumentList $endpoint
try { $listener.Start() } catch { exit 1 }

# Pre-warm: force JIT of the Add-Type'd C# stub by issuing one P/Invoke
# call now. Without this, the FIRST request after cold start can take
# 5-15s while csc.exe + JIT run, during which the client times out and
# closes — leaving the helper stuck in ReadLine on a half-open socket.
[WinSide]::GetForegroundWindow() | Out-Null

Write-Status -Ip $ip -Port $Port -ProcessId $PID

$shouldExit = $false
while (-not $shouldExit) {
    try {
        $client = $listener.AcceptTcpClient()
        $client.NoDelay = $true
        # Fail-fast on dead/half-open clients: if a client connects but
        # doesn't send a full line within 5s, ReadLine throws and we
        # close + accept the next one. Without this, ANY misbehaving
        # connection (e.g. host-side `nc` that closes early) wedges the
        # helper in ReadLine forever and blocks all future PINGs.
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $reader = New-Object System.IO.StreamReader($stream, $utf8NoBom)
        $writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
        $writer.AutoFlush = $true
        while ($null -ne ($line = $reader.ReadLine())) {
            $cmd = $line.Trim()
            if ($cmd -eq '') { continue }
            try {
                if ($cmd -eq 'PING') {
                    $writer.WriteLine('PONG')
                } elseif ($cmd -eq 'FG') {
                    $writer.WriteLine((Get-FG-Line))
                } elseif ($cmd -match '^SET\s+(\d+)$') {
                    $writer.WriteLine((Do-SetForeground -HwndInt ([Int64]$Matches[1])))
                } elseif ($cmd -eq 'LIST') {
                    foreach ($l in (List-Windows)) { $writer.WriteLine($l) }
                    $writer.WriteLine('END')
                } elseif ($cmd -eq 'EXIT') {
                    $writer.WriteLine('OK BYE')
                    $shouldExit = $true
                    break
                } else {
                    $writer.WriteLine("ERR unknown: $cmd")
                }
            } catch {
                try { $writer.WriteLine("ERR exception: $($_.Exception.Message)") } catch {}
            }
        }
        try { $client.Close() } catch {}
    } catch {}
}

try { $listener.Stop() } catch {}
try { Remove-Item -Path $StatusPath -Force -ErrorAction SilentlyContinue } catch {}
"""#
}
