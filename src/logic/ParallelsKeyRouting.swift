import Cocoa

/// REL-114. Parallels' Mac stub for a Windows app (WinAppHelper) shows a "<App> — Starting…"
/// launcher panel until the app it launches comes up. Launched while that Windows app already
/// runs (Windows restarted it after a crash, so it had no helper), the launch never completes and
/// the panel stays up for good: a helper-owned AppKit window with no guest window behind it.
/// Two failures followed on 2026-10-18 (and the same panel trapped Outlook on 2026-10-14):
/// - AltTab listed the panel like a window. Selecting it (16:20:03) made it the helper's key
///   window, so every keystroke "in Outlook" went to the panel.
/// - Parallels arms keyboard routing into the guest when the helper is activated, from the
///   helper's key window at that moment. The helper was activated while the panel was key (the
///   launch at 16:17:08, then AltTab's click-misroute SLPS restore at 16:17:14), and routing
///   stayed off: clicks reached Outlook, keystrokes did not, though AX already reported an
///   Outlook window as focused and the guest foreground was right. Moving key status inside the
///   active helper (AX focus, makeKeyWindow, AltTab's same-process switches) never re-armed it.
///   Deactivating the helper (a click in Chrome) and clicking an Outlook window did (16:17:38).
/// So the panel is hidden from the switcher, and while a helper is trapped (its panel has been
/// its focused window since AltTab last re-armed it) AltTab enters it the way the user's fix
/// did: deactivate the helper if it is in front, send the focus click to the target window while
/// the helper is inactive (Parallels then activates the helper itself, as on a real click), and
/// fall back to the usual SLPS + makeKeyWindow. The panel itself is left alone: it has no close
/// or cancel control, and its only control is a hidden "OK" default button whose effect on the
/// helper is unknown (quitting the helper quits the Windows app).
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
    private static var trappedPanels = [pid_t: CGWindowID]()
    private static var pendingByPid = [pid_t: Int]()
    private static var failuresByPid = [pid_t: Int]()
    private static var lastAttemptAt = [pid_t: CFAbsoluteTime]()
    private static var lastActivationLogAt = [pid_t: CFAbsoluteTime]()
    private static var panelFirstSeen = [CGWindowID: CFAbsoluteTime]()
    private static var stuckPanelsLogged = Set<CGWindowID>()
    private static let reassertSourcesWithUserIntent: Set<String> = ["XPROC", "CLICKAFTER"]
    private static let maxConsecutiveFailures = 3

    /// `Application.focusedWindow` didSet: a launcher panel as the focused window traps the helper.
    static func noteFocusedWindow(of app: Application) {
        guard app.isParallelsCoherence, let window = app.focusedWindow, let wid = window.cgWindowId, window.isParallelsHostPanel else { return }
        let previous = withLock { trappedPanels.updateValue(wid, forKey: app.pid) }
        guard previous != wid else { return }
        Diagnostics.log("PARKEY", "helper pid=\(app.pid) (\(app.localizedName ?? "?")) trapped: its launcher panel #\(wid) is the focused window, so keystrokes miss the Windows app until the helper is re-activated from one of its Windows windows")
    }

    /// Main thread (`Windows.displayHideReasons`). Also logs, once, a panel that outlived the launch.
    static func shouldHideFromSwitcher(_ window: Window) -> Bool {
        guard RuntimeFlags.parallelsHostPanelHidingEnabled, window.isParallelsHostPanel, let wid = window.cgWindowId else { return false }
        logIfStuck(window, wid)
        return true
    }

    static func needsKeySafeActivation(_ app: Application) -> Bool {
        guard RuntimeFlags.parallelsKeySafeActivationEnabled, app.isParallelsCoherence, !backedOff(app.pid) else { return false }
        if app.focusedWindow?.isParallelsHostPanel == true { return true }
        guard let panel = withLock({ trappedPanels[app.pid] }) else { return false }
        guard panel.sharingState() == nil else { return true }
        withLock { trappedPanels[app.pid] = nil }
        Diagnostics.log("PARKEY", "helper pid=\(app.pid) released: launcher panel #\(panel) is gone")
        return false
    }

    /// `Window.focus()`: the user chose a window of a trapped helper.
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
    /// re-assert is handled here: skipped while a key-safe activation of that helper is running
    /// (an SLPS now would activate it with the wrong key window), or turned into one when the user
    /// clicked a window of a trapped helper and another app took the activation.
    static func interceptReassert(_ target: Window, source: String) -> Bool {
        let pid = target.application.pid
        if withLock({ pendingByPid[pid] ?? 0 }) > 0 {
            Diagnostics.log("PARKEY", "\(source) re-assert of #\(target.cgWindowId ?? 0) skipped: key-safe activation of pid=\(pid) in progress")
            return true
        }
        guard reassertSourcesWithUserIntent.contains(source), !target.isParallelsHostPanel, needsKeySafeActivation(target.application),
              CFAbsoluteTimeGetCurrent() - withLock({ lastAttemptAt[pid] ?? 0 }) > 2.5 else { return false }
        activate(target, generation: Windows.currentZOrderFocusGeneration(), reason: source)
        return true
    }

    /// `applicationActivated`: an activation AltTab didn't make (Dock, Cmd-Tab) while the panel holds
    /// the helper's key window leaves keystrokes going nowhere; say so, at most every 10 s per helper.
    static func noteActivation(of app: Application) {
        guard app.isParallelsCoherence, let panel = withLock({ trappedPanels[app.pid] }), withLock({ pendingByPid[app.pid] ?? 0 }) == 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard withLock({ now - (lastActivationLogAt[app.pid] ?? 0) > 10 && now - (lastAttemptAt[app.pid] ?? 0) > 2 }) else { return }
        withLock { lastActivationLogAt[app.pid] = now }
        Diagnostics.log("PARKEY", "helper pid=\(app.pid) activated outside AltTab while launcher panel #\(panel) traps it: keystrokes may miss the Windows app until it is entered through AltTab or by clicking one of its windows from another app")
    }

    private static func run(_ request: Request) {
        defer { withLock { pendingByPid[request.pid, default: 1] -= 1 } }
        guard Windows.isCurrentZOrderFocusGeneration(request.generation) else {
            Diagnostics.log("PARKEY", "key-safe activation of #\(request.wid) skipped: a newer switch superseded it")
            return
        }
        let before = Applications.axFocusedWindowId(pid: request.pid, timeout: 0.15).wid
        let deactivated = deactivateIfFront(request.pid)
        let activatedBy = reactivate(request)
        usleep(120_000)
        report(request, before: before, deactivated: deactivated, activatedBy: activatedBy)
    }

    /// The focus click reaches the target while the helper is inactive, like the user's real click;
    /// if the helper doesn't activate itself from it, AltTab activates it, with the target made the
    /// focused window first so the activation doesn't restore the panel.
    private static func reactivate(_ request: Request) -> String {
        var psn = ProcessSerialNumber()
        GetProcessForPID(request.pid, &psn)
        request.target.makeKeyWindow(&psn)
        let selfActivated = waitFor(milliseconds: RuntimeFlags.parallelsKeySafeSelfActivationWaitMs) { frontPid() == request.pid }
        if !selfActivated {
            focusViaAx(request.target)
            _SLPSSetFrontProcessWithOptions(&psn, request.wid, SLPSMode.userGenerated.rawValue)
            request.target.makeKeyWindow(&psn)
        }
        focusViaAx(request.target)
        return selfActivated ? "helper(click)" : "AltTab(SLPS)"
    }

    /// AX can't see Parallels' keyboard routing (it reported Outlook focused while keystrokes beeped),
    /// so success here only means the helper is in front with the target as its focused window.
    private static func report(_ request: Request, before: CGWindowID?, deactivated: String, activatedBy: String) {
        let after = Applications.axFocusedWindowId(pid: request.pid, timeout: 0.2).wid
        let front = frontPid()
        let ok = front == request.pid && after == request.wid
        let summary = String(format: "key-safe activation of #%u pid=%d (%@): focused before=#%u deactivated=%@ activatedBy=%@ focused after=#%u front=%d %.0fms", request.wid, request.pid, request.reason, before ?? 0, deactivated, activatedBy, after ?? 0, front, (CFAbsoluteTimeGetCurrent() - request.queuedAt) * 1000)
        Diagnostics.log(ok ? "PARKEY" : "ANOMALY", ok ? "\(summary) → helper re-activated on its target" : "\(summary) → helper not re-activated on its target; keystrokes may still miss it")
        withLock { recordOutcome(request.pid, ok) }
    }

    /// After 3 failed attempts in a row, stop for 10 minutes rather than cycle the helper on every switch.
    private static func backedOff(_ pid: pid_t) -> Bool {
        withLock { (failuresByPid[pid] ?? 0) >= maxConsecutiveFailures && CFAbsoluteTimeGetCurrent() - (lastAttemptAt[pid] ?? 0) < 600 }
    }

    private static func recordOutcome(_ pid: pid_t, _ ok: Bool) {
        guard ok else {
            failuresByPid[pid, default: 0] += 1
            return
        }
        trappedPanels[pid] = nil
        failuresByPid[pid] = nil
    }

    /// Deactivation is what re-arms Parallels' routing: AltTab itself takes the front for a moment
    /// (no window, so nothing is raised and stray keystrokes are swallowed, not typed elsewhere).
    private static func deactivateIfFront(_ pid: pid_t) -> String {
        guard frontPid() == pid else { return "no(not front)" }
        var own = ProcessSerialNumber()
        GetProcessForPID(ProcessInfo.processInfo.processIdentifier, &own)
        _SLPSSetFrontProcessWithOptions(&own, 0, SLPSMode.noWindows.rawValue)
        return waitFor(milliseconds: 300) { frontPid() != pid } ? "yes" : "TIMEOUT"
    }

    private static func focusViaAx(_ target: Window) {
        guard let appAx = target.application.axUiElement, let windowAx = target.axUiElement else { return }
        AXUIElementSetMessagingTimeout(appAx, 0.25)
        AXUIElementSetMessagingTimeout(windowAx, 0.25)
        try? appAx.setAttribute(kAXFocusedWindowAttribute, windowAx)
        try? windowAx.focusWindow()
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
