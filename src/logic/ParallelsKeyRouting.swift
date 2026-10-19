import Cocoa

/// REL-114. Parallels' Mac stub for a Windows app (WinAppHelper) shows a "<App> — Starting…"
/// launcher panel until the app it launches comes up. Launched while that Windows app already
/// runs (Windows restarted it after a crash, so it had no helper), the launch never completes and
/// the panel stays up for good: a helper-owned AppKit window with no guest window behind it.
/// While it is up, the helper only routes keystrokes into the guest after it was activated by a
/// click on one of its Windows windows. Measured live 2026-10-18 17:11–17:25 PDT with a Shift
/// press and the guest's GetLastInputInfo: every other way in left keystrokes dead although
/// clicks worked and AX reported an Outlook window focused — AltTab's SLPS + makeKeyWindow
/// activation (5/5), the helper activating itself through AXFrontmost, a real click while it was
/// already active, the focus event record aimed in or outside the window, a click on the panel.
/// A click on an Outlook window while the helper was inactive armed it every time (4/4, real or
/// SkyLight-posted), switches between its windows kept it armed (2/2), and any deactivation
/// disarmed it again. That is also how the user got typing back at 16:17:38 (Chrome, then a
/// click on Outlook), and why the panel, once AltTab listed it and the user picked it (16:20:03),
/// swallowed every keystroke.
/// So the panel is hidden from the switcher, and AltTab enters a trapped helper the way the
/// user's fix did: deactivate it if it is in front (AltTab takes the front, with no window), post
/// a click to the target's top caption row while the helper is inactive (no cursor move), and let
/// the helper activate itself from it. Switches inside a helper AltTab armed take the normal
/// path. The panel itself is left alone: it has no close or cancel control, and its only control
/// is a hidden "OK" default button whose effect on the helper is unknown (quitting the helper
/// quits the Windows app).
enum ParallelsKeyRouting {
    private struct Request {
        let target: Window
        let pid: pid_t
        let wid: CGWindowID
        let generation: Int64
        let reason: String
        let queuedAt: CFAbsoluteTime
    }

    private static let queue = DispatchQueue(label: "alttab.parallelsKeyRouting", qos: .userInteractive)
    private static let lock = NSLock()
    private static var panelsByPid = [pid_t: CGWindowID]()
    private static var armedPids = Set<pid_t>()
    private static var pendingByPid = [pid_t: Int]()
    private static var failuresByPid = [pid_t: Int]()
    private static var lastAttemptAt = [pid_t: CFAbsoluteTime]()
    private static var lastActivationLogAt = [pid_t: CFAbsoluteTime]()
    private static var panelFirstSeen = [CGWindowID: CFAbsoluteTime]()
    private static var stuckPanelsLogged = Set<CGWindowID>()
    private static var captionClicks = 0
    private static let reassertSourcesWithUserIntent: Set<String> = ["XPROC", "CLICKAFTER"]
    private static let maxConsecutiveFailures = 3

    /// Main thread (`Windows.displayHideReasons`). Also logs, once, a panel that outlived the launch.
    static func shouldHideFromSwitcher(_ window: Window) -> Bool {
        guard RuntimeFlags.parallelsHostPanelHidingEnabled, window.isParallelsHostPanel, let wid = window.cgWindowId else { return false }
        logIfStuck(window, wid)
        return true
    }

    /// `Window.focus()`. A helper AltTab armed and that is still in front keeps routing keystrokes
    /// across its own windows; any other entry into a trapped helper needs the click.
    static func needsKeySafeActivation(_ app: Application, alreadyFront: Bool) -> Bool {
        guard RuntimeFlags.parallelsKeySafeActivationEnabled, app.isParallelsCoherence, !backedOff(app.pid), trappingPanel(of: app) != nil else { return false }
        return !(alreadyFront && withLock({ armedPids.contains(app.pid) }))
    }

    /// `Window.focus()` and click-misroute repairs: the user chose a window of a trapped helper.
    static func activate(_ target: Window, generation: Int64, reason: String) {
        guard let wid = target.cgWindowId else { return }
        let request = Request(target: target, pid: target.application.pid, wid: wid, generation: generation, reason: reason, queuedAt: CFAbsoluteTimeGetCurrent())
        withLock {
            pendingByPid[request.pid, default: 0] += 1
            lastAttemptAt[request.pid] = request.queuedAt
        }
        queue.async { run(request) }
    }

    /// `Windows.reassertFrontmostToTarget` for a Coherence target (any thread). True when the
    /// re-assert is handled here: skipped while a key-safe activation of that helper is running (an
    /// SLPS now would activate it from outside and leave keystrokes dead), or turned into one when
    /// the user clicked a window of a trapped helper and another app took the activation.
    static func interceptReassert(_ target: Window, source: String) -> Bool {
        let pid = target.application.pid
        if withLock({ pendingByPid[pid] ?? 0 }) > 0 {
            Diagnostics.log("PARKEY", "\(source) re-assert of #\(target.cgWindowId ?? 0) skipped: key-safe activation of pid=\(pid) in progress")
            return true
        }
        guard reassertSourcesWithUserIntent.contains(source), !target.isParallelsHostPanel,
              needsKeySafeActivation(target.application, alreadyFront: false),
              CFAbsoluteTimeGetCurrent() - withLock({ lastAttemptAt[pid] ?? 0 }) > 2.5 else { return false }
        activate(target, generation: Windows.currentZOrderFocusGeneration(), reason: source)
        return true
    }

    /// `applicationActivated`, for every app. Any other app coming forward deactivated the
    /// helpers, which disarms them; a trapped helper activated by something other than AltTab
    /// (Dock, Cmd-Tab) is not armed, which is logged at most every 10 s per helper.
    static func noteActivation(of app: Application) {
        let now = CFAbsoluteTimeGetCurrent()
        let ours = withLock { (pendingByPid[app.pid] ?? 0) > 0 || now - (lastAttemptAt[app.pid] ?? 0) < 2 }
        withLock { armedPids = armedPids.filter { $0 == app.pid && ours } }
        guard app.isParallelsCoherence, !ours, let panel = withLock({ panelsByPid[app.pid] }),
              withLock({ now - (lastActivationLogAt[app.pid] ?? 0) > 10 }) else { return }
        withLock { lastActivationLogAt[app.pid] = now }
        Diagnostics.log("PARKEY", "trapped helper pid=\(app.pid) (launcher panel #\(panel)) activated outside AltTab: keystrokes miss the Windows app until it is entered through AltTab or by clicking one of its windows from another app")
    }

    /// `Application.focusedWindow` didSet: the panel as the focused window takes the keystrokes.
    static func noteFocusedWindow(of app: Application) {
        guard app.isParallelsCoherence, let window = app.focusedWindow, let wid = window.cgWindowId, window.isParallelsHostPanel else { return }
        let changed = withLock { () -> Bool in
            armedPids.remove(app.pid)
            return panelsByPid.updateValue(wid, forKey: app.pid) != wid
        }
        guard changed else { return }
        Diagnostics.log("PARKEY", "helper pid=\(app.pid) (\(app.localizedName ?? "?")) trapped: its launcher panel #\(wid) is the focused window")
    }

    /// The helper's live launcher panel, if any. On the main thread it is looked up in
    /// `Windows.list`; elsewhere the last lookup is reused while that window still exists.
    private static func trappingPanel(of app: Application) -> CGWindowID? {
        guard Thread.isMainThread else {
            guard let cached = withLock({ panelsByPid[app.pid] }), cached.sharingState() != nil else { return nil }
            return cached
        }
        let panel = Windows.list.first { $0.application.pid == app.pid && $0.isParallelsHostPanel }?.cgWindowId
        let previous = withLock { () -> CGWindowID? in
            let previous = panelsByPid[app.pid]
            panelsByPid[app.pid] = panel
            return previous
        }
        if previous != nil && panel == nil {
            Diagnostics.log("PARKEY", "helper pid=\(app.pid) released: launcher panel #\(previous!) is gone")
        }
        return panel
    }

    private static func run(_ request: Request) {
        defer { withLock { pendingByPid[request.pid, default: 1] -= 1 } }
        guard Windows.isCurrentZOrderFocusGeneration(request.generation) else {
            Diagnostics.log("PARKEY", "key-safe activation of #\(request.wid) skipped: a newer switch superseded it")
            return
        }
        let before = Applications.axFocusedWindowId(pid: request.pid, timeout: 0.15).wid
        let deactivated = deactivateIfFront(request.pid)
        let inactive = frontPid() != request.pid
        captionClicks += 1
        let clickPoint = inactive ? request.target.postSkyLightCaptionClick(shifted: captionClicks % 2 == 0) : nil
        let selfActivated = clickPoint != nil && waitFor(milliseconds: RuntimeFlags.parallelsKeySafeSelfActivationWaitMs) { frontPid() == request.pid }
        if !selfActivated {
            activateFromOutside(request)
        }
        report(request, before: before, deactivated: deactivated, click: clickPoint, selfActivated: selfActivated)
    }

    /// Deactivation is what lets the click re-arm the helper: AltTab itself takes the front for a
    /// moment (no window, so nothing is raised and stray keystrokes are swallowed, not typed elsewhere).
    private static func deactivateIfFront(_ pid: pid_t) -> String {
        guard frontPid() == pid else { return "no(not front)" }
        var own = ProcessSerialNumber()
        GetProcessForPID(ProcessInfo.processInfo.processIdentifier, &own)
        _SLPSSetFrontProcessWithOptions(&own, 0, SLPSMode.noWindows.rawValue)
        return waitFor(milliseconds: 300) { frontPid() != pid } ? "yes" : "TIMEOUT"
    }

    /// The helper didn't activate from the click: activate it the usual way, so at least the
    /// target comes forward (its keystrokes will likely still miss the guest).
    private static func activateFromOutside(_ request: Request) {
        var psn = ProcessSerialNumber()
        GetProcessForPID(request.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, request.wid, SLPSMode.userGenerated.rawValue)
        request.target.makeKeyWindow(&psn)
        guard let appAx = request.target.application.axUiElement, let windowAx = request.target.axUiElement else { return }
        AXUIElementSetMessagingTimeout(appAx, 0.25)
        AXUIElementSetMessagingTimeout(windowAx, 0.25)
        try? appAx.setAttribute(kAXFocusedWindowAttribute, windowAx)
        try? windowAx.focusWindow()
    }

    /// AX can't see Parallels' keyboard routing (it reported Outlook focused while keystrokes went
    /// nowhere); the evidence that the helper is armed is that it activated itself from the click.
    private static func report(_ request: Request, before: CGWindowID?, deactivated: String, click: CGPoint?, selfActivated: Bool) {
        usleep(100_000)
        let after = Applications.axFocusedWindowId(pid: request.pid, timeout: 0.2).wid
        let clickText = click.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
        let summary = String(format: "key-safe activation of #%u pid=%d (%@): focused before=#%u deactivated=%@ captionClick=%@ activatedBy=%@ focused after=#%u front=%d %.0fms", request.wid, request.pid, request.reason, before ?? 0, deactivated, clickText, selfActivated ? "helper(click)" : "AltTab(SLPS)", after ?? 0, frontPid(), (CFAbsoluteTimeGetCurrent() - request.queuedAt) * 1000)
        Diagnostics.log(selfActivated ? "PARKEY" : "ANOMALY", selfActivated ? "\(summary) → armed" : "\(summary) → the helper did not activate from the click; keystrokes likely still miss the Windows app")
        withLock { recordOutcome(request.pid, selfActivated) }
    }

    /// After 3 failed attempts in a row, stop for 10 minutes rather than cycle the helper on every switch.
    private static func backedOff(_ pid: pid_t) -> Bool {
        withLock { (failuresByPid[pid] ?? 0) >= maxConsecutiveFailures && CFAbsoluteTimeGetCurrent() - (lastAttemptAt[pid] ?? 0) < 600 }
    }

    private static func recordOutcome(_ pid: pid_t, _ armed: Bool) {
        guard armed else {
            failuresByPid[pid, default: 0] += 1
            return
        }
        armedPids.insert(pid)
        failuresByPid[pid] = nil
    }

    private static func logIfStuck(_ window: Window, _ wid: CGWindowID) {
        let now = CFAbsoluteTimeGetCurrent()
        let firstSeen = panelFirstSeen[wid] ?? now
        panelFirstSeen[wid] = firstSeen
        guard now - firstSeen >= 30, !stuckPanelsLogged.contains(wid) else { return }
        let guestWindows = Windows.list.filter { $0.application.pid == window.application.pid && $0 !== window }.count
        guard guestWindows > 0 else { return }
        stuckPanelsLogged.insert(wid)
        Diagnostics.log("PARKEY", "launcher panel #\(wid) of pid=\(window.application.pid) (\(window.application.localizedName ?? "?")) still up after \(Int(now - firstSeen))s with \(guestWindows) Windows windows: the launch never finished. Hidden from the switcher and left in place (no close/cancel control; quitting the helper would quit the Windows app). It goes away when the Windows app is quit and relaunched from its Mac stub")
    }

    private static func frontPid() -> pid_t {
        var psn = ProcessSerialNumber()
        guard GetFrontProcess(&psn) == noErr else { return 0 }
        var pid: pid_t = 0
        return GetProcessPID(&psn, &pid) == noErr ? pid : 0
    }

    private static func waitFor(milliseconds: Int, _ condition: () -> Bool) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + Double(milliseconds) / 1000
        while CFAbsoluteTimeGetCurrent() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
