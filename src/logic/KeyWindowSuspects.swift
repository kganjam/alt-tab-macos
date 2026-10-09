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
            if retriesLeft > 0 { scheduleRepair(pid: pid, focusedWid: focusedWid, retriesLeft: retriesLeft - 1) }
            return
        }
        repair(pid: pid, focusedWid: focusedWid)
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

    private static func repair(pid: pid_t, focusedWid: CGWindowID) {
        let targets = suspects.filter { $0.value == pid && $0.key != focusedWid }.keys.compactMap { wid in Windows.list.first { $0.cgWindowId == wid } }
        suspects = suspects.filter { $0.value != pid }
        guard !targets.isEmpty, let back = Windows.list.first(where: { $0.cgWindowId == focusedWid }) else { return }
        lastRepairAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.log("KEYWIN", "repairing suspects \(targets.compactMap { $0.cgWindowId }) pid=\(pid): raise each, then hand key status back to #\(focusedWid)")
        BackgroundWork.accessibilityCommandsQueue.addOperation {
            for window in targets { raise(window) }
            raise(back)
        }
    }

    /// AXRaise is `-[NSWindow makeKeyAndOrderFront:]` in AppKit: a real key transition, so
    /// the next raise delivers the -resignKeyWindow the suspect missed. The AX call is a
    /// synchronous round trip to the app's main thread, so the settle can stay short.
    /// Side effect: the suspect ends up just below the focused window in z-order.
    private static func raise(_ window: Window) {
        guard let element = window.axUiElement else { return }
        AXUIElementSetMessagingTimeout(element, 0.25)
        let err = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        Diagnostics.log("KEYWIN", "AXRaise #\(window.cgWindowId ?? 0) err=\(err.rawValue)")
        usleep(UInt32(RuntimeFlags.keyWindowSuspectRaiseSettleMs * 1000))
    }
}
