import Cocoa

/// Stops AltTab's own window captures while ANOTHER app is screen-recording / sharing, so the
/// switcher stops adding load to a WindowServer that is already compositing a capture stream.
///
/// 2026-11-09 incident: OBS (full-display ScreenCaptureKit stream + a window stream), QuickTime
/// scrubbing and a Teams call were running, and every switcher open fired ~16 visible + ~250
/// deferred captures (40-55/s through replayd, each with a TCC check). WindowServer logged ~2,000
/// `timed out fence` errors and the mouse lagged. None of the existing nets (transition pause,
/// per-window quarantine, latency/expiry breaker) saw it: captures kept completing, just slowly.
///
/// Detection is `CGSIsScreenWatcherPresent`: a read of a byte in WindowServer's shared scoreboard
/// (no mach message, no replayd, ~1ns), true while any client holds a display/content stream. The
/// SystemStatus domain behind the menu-bar indicator would name the app, but systemstatusd
/// rejects clients without its entitlement (verified), and CGWindowList-based indicator probes
/// would hit WindowServer. `ForeignCaptureDetector` filters out our own one-shot SCK screenshots.
///
/// While active: background and session-source captures stop, and on-show captures shrink to the
/// selected window (rate-limited), so tiles keep their cached thumbnails. After the recording
/// ends the background catch-up is throttled for a while, since every window is overdue by then.
final class ScreenCaptureGuard {
    static let shared = ScreenCaptureGuard()

    private let lock = NSLock()
    private var detector = ForeignCaptureDetector()
    private var engagedAt: CFAbsoluteTime = 0
    private var releasedAt: CFAbsoluteTime = 0
    private var announcedArmed = false
    private var suppressedRequests = 0
    private var suppressedWindows = 0
    private var lastSelectedCapture: (wid: CGWindowID, at: CFAbsoluteTime)?
    private let watcherPresent: (@convention(c) () -> Bool)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
    }()

    /// Take one sample (cheap: a lock and a shared-memory byte) and return whether another app is
    /// capturing. Called by the background tick (every 500ms) and by every capture request.
    @discardableResult
    func sample(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard RuntimeFlags.screenCaptureGuardEnabled else { return false }
        guard let watcherPresent else { return announceUnavailableOnce() }
        let own = ActiveWindowCaptures.ownActivity()
        lock.lock()
        detector.confirmSec = Double(RuntimeFlags.screenCaptureGuardConfirmMs) / 1000
        detector.releaseSec = Double(RuntimeFlags.screenCaptureGuardReleaseMs) / 1000
        let present = watcherPresent()
        let armed = announcedArmed ? nil : "screen-capture guard armed: CGSIsScreenWatcherPresent=\(present)"
        announcedArmed = true
        let change = detector.observe(watcherPresent: present, ownInFlight: own.inFlight > 0, ownLastEndedAt: own.lastEndedAt, now: now)
        let active = detector.active
        let summary = record(change, now: now)
        lock.unlock()
        if let armed { Diagnostics.log("CAPTURE", armed) }
        if let summary { Diagnostics.log("CAPTURE", summary) }
        return active
    }

    /// The symbol is private: if a future macOS drops it the guard is simply off. Said once.
    private func announceUnavailableOnce() -> Bool {
        lock.lock()
        let first = !announcedArmed
        announcedArmed = true
        lock.unlock()
        if first { Diagnostics.log("CAPTURE", "screen-capture guard UNAVAILABLE: CGSIsScreenWatcherPresent not found") }
        return false
    }

    /// Caller holds `lock`. Returns the line to log for a transition.
    private func record(_ change: ForeignCaptureDetector.Change, now: CFAbsoluteTime) -> String? {
        switch change {
        case .none: return nil
        case .engaged:
            engagedAt = now
            suppressedRequests = 0
            suppressedWindows = 0
            return "screen-capture guard ENGAGED: another app is screen-capturing — no background captures, on-show captures limited to the selected window; \(ActiveWindowCaptures.pressureLine())"
        case .released:
            releasedAt = now
            return "screen-capture guard released after \(Int(now - engagedAt))s: suppressed \(suppressedWindows) window captures in \(suppressedRequests) requests; background catch-up throttled; \(ActiveWindowCaptures.pressureLine())"
        }
    }

    /// Windows a capture request may actually capture. Everything when nobody else is capturing.
    /// While someone is: nothing for background / session-source / screen-change requests; for
    /// requests made with the switcher open, only the selected window, at most once per
    /// `screenCaptureGuardSelectedMinIntervalMs`.
    func admit(_ windows: [Window], source: RefreshCausedBy, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [Window] {
        guard sample(now: now) else { return windows }
        let allowed = selectedWindowAllowed(windows, source: source, now: now)
        lock.lock()
        suppressedRequests += 1
        suppressedWindows += windows.count - allowed.count
        lock.unlock()
        return allowed
    }

    private func selectedWindowAllowed(_ windows: [Window], source: RefreshCausedBy, now: CFAbsoluteTime) -> [Window] {
        guard source.mayCaptureSelectedWhileForeignCapture, App.appIsBeingUsed,
              let selected = Windows.selectedWindow(), let wid = selected.cgWindowId,
              windows.contains(where: { $0.cgWindowId == wid }) else { return [] }
        let minIntervalSec = Double(RuntimeFlags.screenCaptureGuardSelectedMinIntervalMs) / 1000
        lock.lock(); defer { lock.unlock() }
        if let last = lastSelectedCapture, last.wid == wid, now - last.at < minIntervalSec { return [] }
        lastSelectedCapture = (wid, now)
        return [selected]
    }

    /// Per-tick cap on background captures for a while after a recording ends (every window is
    /// overdue then; `popDue` would otherwise hand out the whole backlog at full speed). Nil = no cap.
    func backgroundCatchUpCap(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard releasedAt > 0, now - releasedAt < Double(RuntimeFlags.screenCaptureGuardCatchUpMs) / 1000 else { return nil }
        return max(1, RuntimeFlags.screenCaptureGuardCatchUpPerTick)
    }

    /// For the THUMBCACHE line.
    var statusLine: String {
        lock.lock(); defer { lock.unlock() }
        return "foreignCapture=\(detector.active) guardSuppressed=\(suppressedWindows)"
    }
}

extension RefreshCausedBy {
    /// With the switcher open the selected window is what the user is looking at; everything else
    /// is cached-thumbnail territory while another app records.
    var mayCaptureSelectedWhileForeignCapture: Bool {
        switch self {
        case .refreshVisibleThumbnailsAfterShowUi, .refreshOnlyThumbnailsAfterShowUi, .refreshUiAfterExternalEvent: return true
        case .screenParametersChanged, .backgroundPeriodic, .sessionSource: return false
        }
    }
}
