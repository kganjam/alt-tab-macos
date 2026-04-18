import SwiftyBeaver
import Foundation
import ScreenCaptureKit

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

    /// Pre-captured full-resolution CGImage (converted from CVPixelBuffer
    /// immediately after capture so it's ready for CALayer.contents).
    static var preCaptureCache: [CGWindowID: CGImage] = [:]

    /// Capture via ScreenCaptureKit at FULL retina resolution.
    /// Returns CVPixelBuffer backed by IOSurface — stays in GPU memory.
    @available(macOS 14.0, *)
    static func preCapture(wid: CGWindowID, position: CGPoint, size: CGSize) {
        let t0 = CACurrentMediaTime()
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let scWindow = content.windows.first(where: { $0.windowID == wid }) else {
                    Diagnostics.log("OVERLAY", "preCapture: SCWindow not found for wid=\(wid)")
                    return
                }
                let config = SCStreamConfiguration()
                let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
                config.width = Int(size.width * scale)
                config.height = Int(size.height * scale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                let pixelBuffer = sampleBuffer.pixelBuffer() ?? sampleBuffer.imageBuffer
                if let pixelBuffer {
                    // Convert CVPixelBuffer → CGImage immediately (CIContext
                    // GPU path). CALayer.contents with IOSurface sublayers
                    // didn't render in our tests. CGImage always works.
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let ctx = CIContext(options: [.useSoftwareRenderer: false])
                    if let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) {
                        let ms = Int((CACurrentMediaTime() - t0) * 1000)
                        preCaptureCache[wid] = cgImage
                        Diagnostics.log("OVERLAY", "SC pre-captured wid=\(wid) \(cgImage.width)x\(cgImage.height) in \(ms)ms")
                    }
                }
            } catch {
                Diagnostics.log("OVERLAY", "SC preCapture error: \(error)")
            }
        }
    }

    static func clearPreCaptureCache() {
        preCaptureCache.removeAll()
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
        guard enabled, let panel = persistentPanel else { return }
        guard let pos = target.position, let sz = target.size else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let screenHeight = screenFrame.height
        // Full screen panel with translucent red outside target area
        panel.setFrame(screenFrame, display: false)
        // Opaque enough to hide ALL Parallels windows (including Excel,
        // other OneNote windows) that might flash during transition.
        // The target's pre-captured image renders on top of this.
        panel.backgroundColor = .black.withAlphaComponent(0.95)

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
        // Use pre-captured CGImage (converted from CVPixelBuffer via CIContext)
        var rendered = false
        if let wid = target.cgWindowId, let img = preCaptureCache[wid] {
            let layer = CALayer()
            layer.contents = img
            layer.contentsGravity = .resizeAspectFill
            layer.frame = frame
            containerView.layer?.addSublayer(layer)
            rendered = true
            Diagnostics.log("OVERLAY", "showing pre-capture \(img.width)x\(img.height)")
            // Verify pixels by sampling center
            let centerColor = img.cropping(to: CGRect(x: img.width/2, y: img.height/2, width: 1, height: 1))
            Diagnostics.log("OVERLAY", "pixel check: center=\(centerColor != nil ? "has data" : "nil")")
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
