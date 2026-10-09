import Cocoa

/// AppKit's `-[NSWindow isKeyWindow]` is a per-window bit (&& `NSApp.isActive`), not a
/// comparison with `NSApp.keyWindow`. When an AltTab switch half-lands — the target app
/// never reports the target as focused before the user moves on, typically because the
/// app's main thread is far behind (Edge with ~450 windows processed one activation 1.6s
/// late) — the target can keep that bit while another window is the real key window: a
/// "phantom key window". In Chromium browsers it then re-forwards every redispatched Cmd
/// shortcut to its own page in a loop, so Cmd+C/V/X/R die in every window until restart.
/// Accessibility can't see the bit (AXFocused/AXMain compare against NSApp), so suspects
/// are inferred: AltTab targets never confirmed by the app's own focused window. Repair is
/// what fixes it by hand: give the suspect real key status, then hand it back.
/// Full write-up: docs/edge-phantom-key-window.md in the dotfiles repo.
enum KeyWindowSuspects {
    private struct Pending {
        let wid: CGWindowID
        let pid: pid_t
    }

    private static var pending: Pending?
    private static var suspects = [CGWindowID: pid_t]()
    private static var lastRepairAt: CFAbsoluteTime = 0

    /// Main thread. Called when AltTab commits to a new focus target.
    static func noteAltTabTarget(_ wid: CGWindowID?) {
        guard RuntimeFlags.keyWindowSuspectTrackingEnabled else { return }
        promoteUnconfirmedPending(newTarget: wid)
        pending = nil
        guard let wid, let window = Windows.list.first(where: { $0.cgWindowId == wid }), isEligible(window) else { return }
        guard !alreadyKey(window) else { return }
        pending = Pending(wid: wid, pid: window.application.pid)
    }

    /// Any thread. The app's own focused window, read from its AX element on activation and
    /// focus/main-window change events.
    static func noteAppFocusedWindow(pid: pid_t, wid: CGWindowID?) {
        guard RuntimeFlags.keyWindowSuspectTrackingEnabled, let wid else { return }
        DispatchQueue.main.async { confirm(pid: pid, wid: wid) }
    }

    private static func confirm(pid: pid_t, wid: CGWindowID) {
        guard NSRunningApplication(processIdentifier: pid)?.isActive == true else { return }
        if pending?.wid == wid { pending = nil }
        if suspects.removeValue(forKey: wid) != nil {
            Diagnostics.log("KEYWIN", "suspect #\(wid) pid=\(pid) cleared: became the app's focused window")
        }
        scheduleRepair(pid: pid, focusedWid: wid)
    }

    private static func promoteUnconfirmedPending(newTarget: CGWindowID?) {
        guard let pending, pending.wid != newTarget,
              Windows.list.contains(where: { $0.cgWindowId == pending.wid }) else { return }
        suspects[pending.wid] = pending.pid
        Diagnostics.log("ANOMALY", "key-window suspect #\(pending.wid) pid=\(pending.pid): AltTab switched away before the app confirmed it as focused (possible phantom key window); suspects=\(suspects.keys.sorted())")
    }

    private static func isEligible(_ window: Window) -> Bool {
        !window.application.isParallelsCoherence && window.application.pid != ProcessInfo.processInfo.processIdentifier
    }

    private static func alreadyKey(_ window: Window) -> Bool {
        window.application.runningApplication.isActive && window.application.focusedWindow?.cgWindowId == window.cgWindowId
    }

    private static func scheduleRepair(pid: pid_t, focusedWid: CGWindowID, retriesLeft: Int = 20) {
        guard RuntimeFlags.keyWindowSuspectRepairEnabled, suspects.values.contains(pid) else { return }
        let generation = Windows.currentZOrderFocusGeneration()
        let scheduledAt = CFAbsoluteTimeGetCurrent()
        let delayMs = retriesLeft == 20 ? RuntimeFlags.keyWindowSuspectRepairDelayMs : 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
            repairIfStillValid(pid: pid, focusedWid: focusedWid, generation: generation, scheduledAt: scheduledAt, retriesLeft: retriesLeft)
        }
    }

    private static func repairIfStillValid(pid: pid_t, focusedWid: CGWindowID, generation: Int64, scheduledAt: CFAbsoluteTime, retriesLeft: Int) {
        guard suspects.values.contains(pid) else { return }
        if let skip = repairSkipReason(pid: pid, focusedWid: focusedWid, generation: generation, scheduledAt: scheduledAt) {
            Diagnostics.log("KEYWIN", "repair for pid=\(pid) deferred: \(skip)")
            return
        }
        guard userIsIdle() else {
            retryLater(pid: pid, focusedWid: focusedWid, retriesLeft: retriesLeft)
            return
        }
        repair(pid: pid, focusedWid: focusedWid, retriesLeft: retriesLeft)
    }

    private static func retryLater(pid: pid_t, focusedWid: CGWindowID, retriesLeft: Int) {
        guard retriesLeft > 0 else { return }
        scheduleRepair(pid: pid, focusedWid: focusedWid, retriesLeft: retriesLeft - 1)
    }

    private static func repairSkipReason(pid: pid_t, focusedWid: CGWindowID, generation: Int64, scheduledAt: CFAbsoluteTime) -> String? {
        if App.appIsBeingUsed { return "switcher open" }
        if !Windows.isCurrentZOrderFocusGeneration(generation) { return "newer AltTab switch" }
        if Windows.userClickedDifferentWindowSince(scheduledAt, targetWid: focusedWid) { return "user clicked elsewhere" }
        if NSRunningApplication(processIdentifier: pid)?.isActive != true { return "app no longer active" }
        if CFAbsoluteTimeGetCurrent() - lastRepairAt < 2 { return "rate limit" }
        return nil
    }

    /// During the repair the suspect is briefly the key window, so keystrokes would land in
    /// it: only repair while the keyboard has been quiet and no mouse button is held.
    private static func userIsIdle() -> Bool {
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return sinceKey >= 1.5 && NSEvent.pressedMouseButtons == 0
    }

    private static func repair(pid: pid_t, focusedWid: CGWindowID, retriesLeft: Int) {
        let suspectWids = suspects.filter { $0.value == pid && $0.key != focusedWid }.map { $0.key }
        let targets = suspectWids.compactMap { wid in Windows.list.first { $0.cgWindowId == wid } }
        suspects = suspects.filter { $0.value != pid }
        guard !targets.isEmpty, let back = Windows.list.first(where: { $0.cgWindowId == focusedWid }) else { return }
        lastRepairAt = CFAbsoluteTimeGetCurrent()
        BackgroundWork.accessibilityCommandsQueue.addOperation {
            if let busy = appBusyReason(pid: pid, expecting: focusedWid) {
                DispatchQueue.main.async { requeue(suspectWids, pid: pid, focusedWid: focusedWid, retriesLeft: retriesLeft, reason: busy) }
                return
            }
            Diagnostics.log("KEYWIN", "repairing suspects \(suspectWids) pid=\(pid): raise each, then hand key status back to #\(focusedWid)")
            for window in targets { raise(window) }
            handBack(to: back, pid: pid)
        }
    }

    private static func requeue(_ wids: [CGWindowID], pid: pid_t, focusedWid: CGWindowID, retriesLeft: Int, reason: String) {
        wids.forEach { suspects[$0] = pid }
        lastRepairAt = 0
        Diagnostics.log("KEYWIN", "repair for pid=\(pid) deferred: \(reason)")
        retryLater(pid: pid, focusedWid: focusedWid, retriesLeft: retriesLeft)
    }

    /// A backlogged main thread applies AX requests late, out of order with the user's next
    /// switch — exactly how phantoms form (2026-10-08 21:45: Edge ~3s behind, the hand-back
    /// raise timed out, landed late, and split key/main across two windows). Only repair
    /// when the app answers promptly and still reports the window we will hand back to.
    private static func appBusyReason(pid: pid_t, expecting wid: CGWindowID) -> String? {
        let probe = focusedWindow(pid: pid, timeout: 0.3)
        guard let focused = probe.wid else { return String(format: "app unresponsive (probe %.0fms, no focused window)", probe.ms) }
        if probe.ms > Double(RuntimeFlags.keyWindowSuspectMaxProbeMs) { return String(format: "app busy (probe %.0fms)", probe.ms) }
        if focused != wid { return "focus moved to #\(focused)" }
        return nil
    }

    private static func focusedWindow(pid: pid_t, timeout: Float) -> (wid: CGWindowID?, ms: Double) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let start = CFAbsoluteTimeGetCurrent()
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        guard err == .success, let value else { return (nil, ms) }
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(value as! AXUIElement, &wid)
        return (wid == 0 ? nil : wid, ms)
    }

    private static func handBack(to window: Window, pid: pid_t) {
        guard let wid = window.cgWindowId else { return }
        for attempt in 1...2 {
            raise(window)
            let focused = focusedWindow(pid: pid, timeout: 1).wid
            Diagnostics.log("KEYWIN", "hand-back to #\(wid) attempt \(attempt): focused=#\(focused ?? 0)")
            if focused == wid { return }
        }
        Diagnostics.log("ANOMALY", "key-window repair could not hand key status back to #\(wid) pid=\(pid)")
    }

    /// AXRaise is `-[NSWindow makeKeyAndOrderFront:]` in AppKit: a real key transition, so
    /// the next raise delivers the -resignKeyWindow the suspect missed. The long timeout
    /// keeps each raise synchronous: a timed-out raise is still applied later, out of order.
    /// Side effect: the suspect ends up just below the focused window in z-order.
    private static func raise(_ window: Window) {
        guard let element = window.axUiElement else { return }
        AXUIElementSetMessagingTimeout(element, Float(RuntimeFlags.keyWindowSuspectRaiseTimeoutMs) / 1000)
        let err = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        Diagnostics.log("KEYWIN", "AXRaise #\(window.cgWindowId ?? 0) err=\(err.rawValue)")
        usleep(UInt32(RuntimeFlags.keyWindowSuspectRaiseSettleMs * 1000))
    }
}
