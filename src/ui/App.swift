import Cocoa
import Darwin
import LetsMove
import ShortcutRecorder
import AppCenterCrashes

class App: AppCenterApplication {
    /// periphery:ignore
    static let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Prevent App Nap to preserve responsiveness")
    static let bundleIdentifier = Bundle.main.bundleIdentifier!
    static let bundleURL = Bundle.main.bundleURL
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String
    /// Custom-build version string shown in the About panel. Reads the
    /// bundle-plist value (normally `#VERSION#` placeholder from a local
    /// build) and prepends a clear "CUSTOM BUILD" marker so it's obvious
    /// the user is running our patched version rather than the official
    /// release. The timestamp is baked at compile time via the BUILD_DATE
    /// preprocessor-ish approach — we use a static string updated by the
    /// local build wrapper script.
    static let version: String = {
        let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let buildDate = "2026-05-19 12:53 dev" // updated by build script
        return "CUSTOM BUILD (\(buildDate)) — base:\(bundleVersion)"
    }()
    static let licence = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as! String
    static let repository = "https://github.com/lwouis/alt-tab-macos"
    static let website = "https://alt-tab.app"
    static let appIcon = CGImage.named("app.icns")
    override class var shared: App { super.shared as! App }
    static var supportProjectAction: Selector { #selector(App.supportProject) }
    static var isTerminating = false
    static var appIsBeingUsed = false
    static var shortcutIndex = 0
    static var forceDoNothingOnRelease = false
    private static var focusTargetSuppressionUntil: CFAbsoluteTime = 0
    private static var focusTargetSuppressionReason = ""
    /// Captured at the start of each AltTab session so that focus() can tell
    /// which window was REALLY in the foreground when the user hit Alt-Tab.
    /// Tracked by CGWindowID (not pid) so that switching between two
    /// windows of the same app (e.g. two OneNote windows both under a
    /// single Parallels winapp process) properly rotates between them.
    static var sessionSourceWid: CGWindowID?
    /// The `sessionSourceWid` from the PREVIOUS AltTab session — the
    /// window the user was on before they alt-tabbed to the current
    /// foreground. Used to set position 1 in the switcher list.
    static var previousSessionSourceWid: CGWindowID?
    /// The last target wid we focused via our own AltTab transition.
    /// This is the ground truth for "which window is currently
    /// foreground" — more reliable than `Applications.frontmostPid`
    /// (which can be flipped by delayed Parallels AX events after our
    /// guard expires) or NSWorkspace (which lags). Used at session
    /// start to decide the current frontmost window when other signals
    /// disagree.
    static var lastFocusedTargetWid: CGWindowID?
    /// pid of the same target. Used by CLICKMISROUTE to distinguish
    /// "wrong app" (cross-pid) from "different window of same app"
    /// (cross-wid, same-pid) — the latter is usually just user
    /// clicking outside a small alt-tab target's bounds, not a bug.
    static var lastFocusedTargetPid: pid_t?
    /// When `lastFocusedTargetWid` was last set. Used by the
    /// CLICKMISROUTE diagnostic to age-out the "expected target" so a
    /// user clicking around 30 seconds after a switch isn't flagged as
    /// a misroute.
    static var lastFocusedTargetTime: CFAbsoluteTime?
    static var lastAltTabFocusTargetWid: CGWindowID?
    static var lastAltTabFocusSourceWid: CGWindowID?
    static var lastAltTabFocusAt: CFAbsoluteTime = 0
    static var altTabFocusSourceInvalidated = true
    private static let thumbnailCaptureGateLock = NSLock()
    private static var thumbnailCaptureGateToken: UInt64 = 0
    private static var thumbnailCaptureGateUntil: CFAbsoluteTime = 0
    private static var thumbnailCaptureGateReason = ""
    private static var pendingParCaptureGateToken: UInt64?
    /// Register-once guard for the global mouse-click NSEvent monitor.
    /// Without this, duplicate `[DIAG MOUSE]` lines appeared per click.
    static var globalClickMonitorRegistered = false
    /// Mirror of `sessionSourceWid` as a pid, exposed as before for the
    /// existing Parallels-outbound detection which only needs to know
    /// the source app. Kept in sync via rotation.
    static var sessionSourcePid: pid_t? {
        guard let wid = sessionSourceWid,
              let w = (Windows.list.first { $0.cgWindowId == wid }) else { return nil }
        return w.application.pid
    }

    static func noteAltTabFocusIntent(targetWid: CGWindowID?) {
        lastAltTabFocusTargetWid = targetWid
        lastAltTabFocusSourceWid = sessionSourceWid
        lastAltTabFocusAt = CFAbsoluteTimeGetCurrent()
        altTabFocusSourceInvalidated = false
        Diagnostics.log("RECENCY", "altTab intent source=#\(sessionSourceWid ?? 0) target=#\(targetWid ?? 0)")
    }

    static func noteDirectFocusOutsideAltTab(_ wid: CGWindowID?) {
        if appIsBeingUsed {
            Diagnostics.log("PANEL", "external/direct focus canceled active AltTab handoff wid=#\(wid ?? 0)")
            cancelPendingParHide()
            hideUi(true)
        } else {
            cancelPendingParHide()
        }
        altTabFocusSourceInvalidated = true
        Diagnostics.log("RECENCY", "external/direct focus invalidated AltTab pair wid=#\(wid ?? 0)")
    }

    static func noteObservedFocusedWindow(_ wid: CGWindowID?) {
        guard let wid, let targetWid = lastAltTabFocusTargetWid, wid != targetWid else { return }
        altTabFocusSourceInvalidated = true
        Diagnostics.log("RECENCY", "observed non-target focus invalidated AltTab pair wid=#\(wid) target=#\(targetWid)")
    }

    static func shouldSuppressStaleAltTabTargetEvent(wid: CGWindowID?, pid: pid_t?, reason: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard altTabFocusSourceInvalidated,
              let wid,
              let pid,
              let targetWid = lastAltTabFocusTargetWid,
              wid == targetWid,
              now - lastAltTabFocusAt < Double(RuntimeFlags.postAltTabFocusSuppressionMs) / 1000,
              Windows.recentExternalKeyboardInputFollowsAltTabTarget(requireReleasable: true) else { return false }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let topWid = Windows.captureTopZRanking(maxCount: 1).first?.wid
        guard frontPid != pid || topWid != wid else { return false }
        Diagnostics.log("RECENCY", "suppress stale target focus event after external ownership reason=\(reason) wid=#\(wid) pid=\(pid) frontPid=\(frontPid ?? 0) top=#\(topWid ?? 0)")
        return true
    }

    @discardableResult
    static func blockThumbnailCaptures(reason: String, timeoutMs: Int) -> UInt64 {
        guard RuntimeFlags.thumbnailCaptureSettleGateEnabled else { return 0 }
        let until = CFAbsoluteTimeGetCurrent() + Double(timeoutMs) / 1000
        thumbnailCaptureGateLock.lock()
        thumbnailCaptureGateToken += 1
        let token = thumbnailCaptureGateToken
        thumbnailCaptureGateUntil = until
        thumbnailCaptureGateReason = reason
        thumbnailCaptureGateLock.unlock()
        Diagnostics.log("CAPTURE", "thumbnail gate begin token=\(token) reason=\(reason) timeout=\(timeoutMs)ms")
        return token
    }

    static func releaseThumbnailCaptureGate(_ token: UInt64, reason: String) {
        guard token > 0 else { return }
        thumbnailCaptureGateLock.lock()
        let shouldRelease = token == thumbnailCaptureGateToken
        if shouldRelease {
            thumbnailCaptureGateUntil = 0
            thumbnailCaptureGateReason = ""
        }
        thumbnailCaptureGateLock.unlock()
        guard shouldRelease else { return }
        Diagnostics.log("CAPTURE", "thumbnail gate end token=\(token) reason=\(reason)")
    }

    static func thumbnailCaptureAllowed(_ source: RefreshCausedBy, logBlocked: Bool = true) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        // Post-selection pause: after the user commits an alt-tab choice,
        // suppress ALL captures for `bgThumbnailPostSelectionPauseMs` so
        // we don't compete with the focus handoff. This also catches
        // delayed timer callbacks (in-panel 1200ms timer fires queued
        // before hideUi, deferred buildUiAndShowPanel reshots, 1s screen-
        // change reissue) — none of them should run inside the pause.
        // Lifted when the panel reopens (`appIsBeingUsed == true`) since
        // the user is then back in interactive mode and wants fresh tiles.
        if !appIsBeingUsed && lastAltTabFocusAt > 0 {
            let pauseSec = Double(RuntimeFlags.bgThumbnailPostSelectionPauseMs) / 1000
            let sinceSelection = now - lastAltTabFocusAt
            if sinceSelection < pauseSec {
                if logBlocked {
                    Diagnostics.log("CAPTURE", "thumbnail capture blocked source=\(source) reason=post-selection-pause remaining=\(Int((pauseSec - sinceSelection) * 1000))ms")
                }
                return false
            }
        }
        guard RuntimeFlags.thumbnailCaptureSettleGateEnabled else { return true }
        thumbnailCaptureGateLock.lock()
        let blocked = thumbnailCaptureGateUntil > now
        let remainingMs = max(0, Int((thumbnailCaptureGateUntil - now) * 1000))
        let reason = thumbnailCaptureGateReason
        thumbnailCaptureGateLock.unlock()
        guard blocked else { return true }
        if logBlocked {
            Diagnostics.log("CAPTURE", "thumbnail capture blocked source=\(source) reason=\(reason) remaining=\(remainingMs)ms")
        }
        return false
    }

    static func deferStaleInputCaptureHideIfFocusIsSettling() -> Bool {
        guard pendingParCaptureGateToken != nil else { return false }
        Diagnostics.log("CAPTURE", "keyboard stale input capture deferred during par focus settle")
        startInputCaptureWatchdog()
        return true
    }

    static func shouldSuppressPostAltTabFocusEvent(wid: CGWindowID?, pid: pid_t?, reason: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard let targetWid = lastAltTabFocusTargetWid,
              !altTabFocusSourceInvalidated,
              now - lastAltTabFocusAt < Double(RuntimeFlags.postAltTabFocusSuppressionMs) / 1000 else { return false }
        if wid == targetWid { return false }
        let sourceWid = lastAltTabFocusSourceWid
        let targetPid = Windows.list.first { $0.cgWindowId == targetWid }?.application.pid
        let sourcePid = sourceWid.flatMap { sourceWid in Windows.list.first { $0.cgWindowId == sourceWid }?.application.pid }
        let isTargetAppSiblingEvent = pid != nil && pid == targetPid && wid != nil && wid != targetWid
        if isTargetAppSiblingEvent {
            if let wid, let pid, Windows.releaseZOrderEnforcementForSameAppKeyboardFocusMove(wid: wid, pid: pid, label: reason) {
                altTabFocusSourceInvalidated = true
                Diagnostics.log("RECENCY", "allow target-app sibling focus event after keyboard reason=\(reason) wid=#\(wid) target=#\(targetWid)")
                return false
            }
            let timeSinceClick = now - Windows.lastMouseClickTime
            guard timeSinceClick >= 0.3 else {
                altTabFocusSourceInvalidated = true
                Diagnostics.log("RECENCY", "allow target-app sibling focus event after user click reason=\(reason) wid=#\(wid ?? 0) target=#\(targetWid)")
                return false
            }
            Diagnostics.log("RECENCY", "suppress stale target-app sibling focus event reason=\(reason) wid=#\(wid ?? 0) target=#\(targetWid) age=\(Int((now - lastAltTabFocusAt) * 1000))ms")
            return true
        }
        let isSourceWindowEvent = wid != nil && wid == sourceWid
        let isSourceAppEvent = pid != nil && pid == sourcePid && sourcePid != targetPid
        guard isSourceWindowEvent || isSourceAppEvent else { return false }
        let timeSinceClick = now - Windows.lastMouseClickTime
        guard timeSinceClick >= 0.3 else {
            altTabFocusSourceInvalidated = true
            Diagnostics.log("RECENCY", "allow post-AltTab focus event after user click reason=\(reason) wid=#\(wid ?? 0) pid=\(pid ?? 0)")
            return false
        }
        Diagnostics.log("RECENCY", "suppress stale post-AltTab focus event reason=\(reason) wid=#\(wid ?? 0) pid=\(pid ?? 0) source=#\(sourceWid ?? 0) target=#\(targetWid) age=\(Int((now - lastAltTabFocusAt) * 1000))ms")
        return true
    }

    static func preferredPreviousWidAtSessionStart(currentWid: CGWindowID?, recencyPreviousWid: CGWindowID?) -> CGWindowID? {
        guard let currentWid,
              currentWid == lastAltTabFocusTargetWid,
              !altTabFocusSourceInvalidated,
              let sourceWid = lastAltTabFocusSourceWid else { return recencyPreviousWid }
        Diagnostics.log("RECENCY", "using AltTab pair previous=#\(sourceWid) current=#\(currentWid)")
        return sourceWid
    }

    private static var isFirstSummon = true
    private static var isVeryFirstSummon = true
    private static var pendingShowSettingsWindow = false
    // periphery:ignore
    private static var appCenterDelegate: AppCenterCrash?
    // don't queue multiple delayed rebuildUi() calls
    private static var delayedDisplayScheduled = 0
    private static var delayedDisplayToken = 0
    private static let refreshOpenUiThrottler = Throttler(delayInMs: 200)
    private static var inputCaptureToken = 0
    private static var inputCaptureStartedAt: CFAbsoluteTime = 0
    private static var inputCaptureLastActivityAt: CFAbsoluteTime = 0
    private static var parHideToken = 0
    private static var parHideVisualReassertedToken = 0
    private static var parHideVisualReassertCount = 0
    private static var parHideVisualReassertAt: CFAbsoluteTime = 0
    private struct ParGuestForegroundState {
        var targetTitle: String
        var readySince: CFAbsoluteTime?
        var lastProbeAt: CFAbsoluteTime = 0
        var probeInFlight = false
        var lastTitle = ""
        var lastHwnd = 0
        var lastPid = 0
        var lastSetAt: CFAbsoluteTime = 0
        var setInFlight = false
        var setAttempts = 0
    }
    private static var parGuestForegroundStates = [Int: ParGuestForegroundState]()

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    /// we put application code here which should be executed on init() and Preferences change
    static func resetPreferencesDependentComponents() {
        TilesView.reset()
    }

    private static var didCallRestart = false
    private static let restartLockPath = "/tmp/alttab-restart.lock"
    private static let restartLockWindowMs: Double = 5000

    static func restart() {
        // Why this is a fork-bomb without a guard: there are ~9 callers of
        // restart() — almost all "if my event tap couldn't be created,
        // bounce the process". When TCC for Input Monitoring is in a
        // flaky state (e.g., multiple registered code-signatures, fresh
        // rebuild not yet authorized), every spawned process fails the
        // same way, calls restart(), spawns ANOTHER one with `open -n`
        // (which bypasses the running-instance check), and dies. The
        // children survive their parent. Within seconds the screen is
        // littered with PermissionsWindow popups from many parallel
        // instances.
        //
        // Two-tier guard:
        //  1. Process-local: each instance restarts at most once.
        //  2. Filesystem mtime: if ANY instance restarted within the
        //     last 5s, suppress this one — just terminate without
        //     spawning a successor. The first restarter wins.
        if didCallRestart {
            Logger.error { "restart() called twice in same process — ignoring" }
            return
        }
        didCallRestart = true
        // Permission-aware suppression. Most restart() callers are
        // "my CGEvent tap couldn't be created — try again from scratch."
        // If the underlying cause is "TCC denied this cert hash for
        // Input Monitoring / Accessibility", spawning a successor with
        // `open -n` will hit the SAME wall, fail the same way, and
        // queue ANOTHER tccd prompt via UserNotificationCenter — which
        // lingers in the system queue even after the AltTab process
        // exits. Observed symptom: dozens of stale "AltTab would like
        // to control your computer using accessibility features"
        // popups long after every AltTab pid is gone, with the queue
        // only flushing when UserNotificationCenter is killed. Since
        // a respawn won't recover, suppress the spawn entirely when
        // AX is denied: stay running, show the permissions window,
        // and let the user grant access in System Settings.
        let axTrusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary)
        if !axTrusted {
            Logger.error { "restart() suppressed: AX denied; respawn would only queue another tccd prompt" }
            DispatchQueue.main.async {
                SystemPermissions.preStartupPermissionsPassed = false
                App.showPermissionsWindow()
            }
            return
        }
        let now = Date().timeIntervalSince1970
        if let attrs = try? FileManager.default.attributesOfItem(atPath: restartLockPath),
           let mtime = attrs[.modificationDate] as? Date {
            let ageMs = (now - mtime.timeIntervalSince1970) * 1000
            if ageMs < restartLockWindowMs {
                Logger.error { "restart() suppressed: another instance restarted \(Int(ageMs))ms ago — terminating only" }
                App.shared.terminate(nil)
                return
            }
        }
        try? "\(now)".write(toFile: restartLockPath, atomically: true, encoding: .utf8)
        // we use -n to open a new instance, to avoid calling applicationShouldHandleReopen
        // we use Bundle.main.bundlePath in case of multiple AltTab versions on the machine
        printStackTrace()
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-n", Bundle.main.bundlePath])
        App.shared.terminate(nil)
    }

    static func hideUi(_ keepPreview: Bool = false) {
        Logger.info { "appIsBeingUsed:\(appIsBeingUsed)" }
        guard appIsBeingUsed else { return } // already hidden
        Diagnostics.log("PANEL", "hideUi keepPreview=\(keepPreview)")
        parHideToken += 1
        parGuestForegroundStates.removeAll()
        // Phase 1 — sync state flip + the visible step. `appIsBeingUsed=false`
        // first so the deferred-cleanup re-entry guard is correct; tile-panel
        // orderOut second so the user-perceived latency for Mac→Mac ends here
        // (target window has already been raised by `window.focus()` upstream
        // under H1 ordering, so the orderOut reveals it instantly).
        // `sessionSourcePid` intentionally NOT cleared — overwritten in
        // `showUiOrCycleSelection` on the next session.
        appIsBeingUsed = false
        isFirstSummon = true
        forceDoNothingOnRelease = false
        clearFocusTargetSuppression()
        TilesView.stopVisibleThumbnailRefreshTimer()
        endInputCapture()
        hideTilesPanelWithoutChangingKeyWindow()
        // Phase 2 — defer the slow cleanup to the next runloop. Event-tap
        // teardown (CursorEvents/ContextMenuEvents), tooltip private-API
        // call, and MainMenu rebuild together cost 10–50 ms on the main
        // thread; running them inline pushed the perceived end-of-switch
        // out by that amount. The deferred handlers all guard on
        // `appIsBeingUsed`, so a re-entrant Cmd-Tab arriving in this
        // window finds the flag already false and behaves correctly.
        DispatchQueue.main.async {
            UsageStats.resetSession()
            TilesView.endSearchSession()
            ContextMenuEvents.toggle(false)
            if !keepPreview {
                PreviewPanel.shared.orderOut(nil)
            }
            hideAllTooltips()
            MainMenu.toggle(true)
        }
    }

    private static func startInputCaptureWatchdog(resetCaptureAge: Bool = false) {
        inputCaptureToken += 1
        let token = inputCaptureToken
        if resetCaptureAge || inputCaptureStartedAt == 0 {
            inputCaptureStartedAt = CFAbsoluteTimeGetCurrent()
        }
        let timeoutMs = RuntimeFlags.inputCaptureWatchdogMs
        guard timeoutMs > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
            guard appIsBeingUsed && token == inputCaptureToken else { return }
            Diagnostics.log("CAPTURE", "watchdog hiding stuck input capture after \(timeoutMs)ms")
            hideUi()
        }
    }

    static func noteInputCaptureActivity(_ reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { noteInputCaptureActivity(reason) }
            return
        }
        guard appIsBeingUsed else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - inputCaptureLastActivityAt >= 0.25 else { return }
        inputCaptureLastActivityAt = now
        startInputCaptureWatchdog()
    }

    private static func endInputCapture() {
        inputCaptureToken += 1
        inputCaptureStartedAt = 0
        inputCaptureLastActivityAt = 0
        CursorEvents.toggle(false)
        TrackpadEvents.reset()
    }

    static func inputCaptureIsOlderThan(_ thresholdMs: Int) -> Bool {
        guard thresholdMs > 0, inputCaptureStartedAt > 0 else { return false }
        return (CFAbsoluteTimeGetCurrent() - inputCaptureStartedAt) * 1000 >= Double(thresholdMs)
    }

    /// some tooltips may not be hidden when the main window is hidden; we force it through a private API
    private static func hideAllTooltips() {
        let selector = NSSelectorFromString("abortAllToolTips")
        if NSApp.responds(to: selector) {
            NSApp.perform(selector)
        }
    }

    /// we don't want another window to become key when the TilesPanel is hidden
    static func hideTilesPanelWithoutChangingKeyWindow() {
        allSecondaryWindowsCanBecomeKey(false)
        TilesPanel.shared.orderOut(nil)
        allSecondaryWindowsCanBecomeKey(true)
    }

    private static func allSecondaryWindowsCanBecomeKey(_ canBecomeKey_: Bool) {
        SettingsWindow.canBecomeKey_ = canBecomeKey_
        AboutWindow.canBecomeKey_ = canBecomeKey_
        PermissionsWindow.canBecomeKey_ = canBecomeKey_
        FeedbackWindow.canBecomeKey_ = canBecomeKey_
        DebugWindow.canBecomeKey_ = canBecomeKey_
    }

    static func closeSelectedWindow() {
        let window = Windows.selectedWindow()
        window?.close()
        Windows.requestZOrderReview(reason: "alttab-close", wid: window?.cgWindowId ?? 0, invalidate: window?.cgWindowId != nil, fullDelayMs: 500)
    }

    static func minDeminSelectedWindow() {
        let window = Windows.selectedWindow()
        window?.minDemin()
        Windows.requestZOrderReview(reason: "alttab-min-demin", wid: window?.cgWindowId ?? 0, invalidate: window?.cgWindowId != nil, fullDelayMs: 500)
    }

    static func toggleFullscreenSelectedWindow() {
        let window = Windows.selectedWindow()
        window?.toggleFullscreen()
        Windows.requestZOrderReview(reason: "alttab-fullscreen", wid: window?.cgWindowId ?? 0, fullDelayMs: 700)
    }

    static func quitSelectedApp() {
        let window = Windows.selectedWindow()
        window?.application.quit()
        Windows.requestZOrderReview(reason: "alttab-quit", wid: window?.cgWindowId ?? 0, invalidate: window?.cgWindowId != nil, fullDelayMs: 700)
    }

    static func hideShowSelectedApp() {
        let window = Windows.selectedWindow()
        window?.application.hideOrShow()
        Windows.requestZOrderReview(reason: "alttab-hide-show", wid: window?.cgWindowId ?? 0, fullDelayMs: 500)
    }

    static func toggleSearchMode() {
        guard appIsBeingUsed else { return }
        TilesView.toggleSearchModeFromShortcut()
    }

    static func lockSearchMode() {
        guard appIsBeingUsed, TilesView.isSearchModeOn else { return }
        TilesView.lockSearchMode()
    }

    static func cancelSearchModeOrHideUi() {
        guard appIsBeingUsed else { return }
        if TilesView.isSearchModeOn {
            TilesView.disableSearchMode()
        } else {
            hideUi()
        }
    }

    static func suppressFocusTargetUntilHide(reason: String, timeoutMs: Int = 2500) {
        focusTargetSuppressionUntil = CFAbsoluteTimeGetCurrent() + Double(timeoutMs) / 1000
        focusTargetSuppressionReason = reason
        Diagnostics.log("KEY", "suppress focusTarget until hide reason=\(reason) timeout=\(timeoutMs)ms")
    }

    private static func clearFocusTargetSuppression() {
        focusTargetSuppressionUntil = 0
        focusTargetSuppressionReason = ""
    }

    private static func focusTargetIsSuppressed() -> Bool {
        let remainingMs = Int((focusTargetSuppressionUntil - CFAbsoluteTimeGetCurrent()) * 1000)
        guard remainingMs > 0 else {
            clearFocusTargetSuppression()
            return false
        }
        Diagnostics.markSwitchPhase("focusTargetIgnored", extra: focusTargetSuppressionReason)
        Diagnostics.log("KEY", "ignored focusTarget during \(focusTargetSuppressionReason) remaining=\(remainingMs)ms")
        return true
    }

    static func focusTarget() {
        guard appIsBeingUsed else { return } // already hidden
        guard !focusTargetIsSuppressed() else { return }
        Diagnostics.markSwitchPhase("focusTarget")
        let selectedWindow = Windows.selectedWindow()
        Logger.info { selectedWindow?.debugId }
        focusSelectedWindow(selectedWindow)
    }

    @objc static func checkForUpdatesNow(_ sender: NSMenuItem) {
        GeneralTab.checkForUpdatesNow(sender)
    }

    @objc static func checkPermissions(_ sender: NSMenuItem) {
        showPermissionsWindow()
    }

    @objc static func supportProject() {
        NSWorkspace.shared.open(URL(string: App.website + "/support")!)
    }

    @objc static func showFeedbackPanel() {
        initializeFeedbackWindowIfNeeded()
        showSecondaryWindow(FeedbackWindow.shared!)
    }

    @objc static func showDebugWindow() {
        initializeDebugWindowIfNeeded()
        showSecondaryWindow(DebugWindow.shared!)
    }

    @objc static func showSettingsWindow() {
        guard Menubar.statusItem != nil else {
            pendingShowSettingsWindow = true
            return
        }
        initializeSettingsWindowIfNeeded()
        showSecondaryWindow(SettingsWindow.shared!)
        if SettingsWindow.shared!.isVisible != true {
            let window = SettingsWindow()
            showSecondaryWindow(window)
            window.orderFrontRegardless()
        }
    }

    @objc static func toggleOverlayMode() {
        let newValue = !FocusOverlay.overlayModeEnabled
        UserDefaults.standard.set(newValue, forKey: "overlayMode")
        updateParallelsMenuStates()
        if newValue {
            if #available(macOS 14.0, *) {
                FocusOverlay.createPersistentOverlay()
                FocusOverlay.startBackgroundRefresh()
            }
        } else {
            FocusOverlay.dismiss()
            FocusOverlay.clearPreCaptureCache()
            FocusOverlay.stopBackgroundRefresh()
        }
        Diagnostics.log("OVERLAY", "overlay mode \(newValue ? "ON" : "OFF")")
    }

    @objc static func toggleHideSource() {
        let key = "hideSourceWindow"
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)
        updateParallelsMenuStates()
        Diagnostics.log("HIDE", "hide source window \(newValue ? "ON" : "OFF")")
    }

    @objc static func toggleCoherencePreviews() {
        let key = "disableCoherencePreviews"
        let newDisabled = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newDisabled, forKey: key)
        updateParallelsMenuStates()
    }

    @objc static func toggleDiagnostics() {
        let key = "diagnosticsEnabled"
        let newValue = !Diagnostics.enabled
        UserDefaults.standard.set(newValue, forKey: key)
        updateParallelsMenuStates()
    }

    @objc static func toggleWinsideHelper() {
        let newValue = !Winside.isEnabled
        Winside.setEnabled(newValue)
        updateParallelsMenuStates()
    }

    @objc static func flushStuckAuthPopupsAction() {
        let n = SystemPermissions.countUserNotificationCenterWindows()
        Diagnostics.log("AUTHCHECK", "manual flush triggered; \(n) UserNotificationCenter windows on screen")
        SystemPermissions.flushStuckAuthPopups()
    }

    private static func updateParallelsMenuStates() {
        guard let parallelsItem = Menubar.menu.items.first(where: { $0.title == "Parallels Mode" }),
              let sub = parallelsItem.submenu else { return }
        for item in sub.items {
            switch item.title {
            case "Enable Overlay Mode": item.state = FocusOverlay.overlayModeEnabled ? .on : .off
            case "Hide Source Window": item.state = UserDefaults.standard.bool(forKey: "hideSourceWindow") ? .on : .off
            case "Coherence Thumbnails": item.state = !UserDefaults.standard.bool(forKey: "disableCoherencePreviews") ? .on : .off
            case "Diagnostics Logging": item.state = Diagnostics.enabled ? .on : .off
            case "Windows Helper (Phase 3 IPC)": item.state = Winside.isEnabled ? .on : .off
            default: break
            }
        }
    }

    @objc static func showAboutWindow() {
        initializeAboutWindowIfNeeded()
        showSecondaryWindow(AboutWindow.shared!)
    }

    static func showSecondaryWindow(_ window: NSWindow) {
        NSScreen.updatePreferred()
        App.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // if the window was resized/repositioned by the user, restore the window the way it was
        let restored = window.setFrameUsingName(window.frameAutosaveName)
        if !restored {
            NSScreen.preferred.repositionPanel(window)
            // Use the center function to continue to center, the `repositionPanel` function cannot center, it may be a system bug
            window.center()
        }
    }

    private static func initializeSettingsWindowIfNeeded() {
        if SettingsWindow.shared == nil { _ = SettingsWindow() }
    }

    private static func initializeAboutWindowIfNeeded() {
        if AboutWindow.shared == nil { _ = AboutWindow() }
    }

    private static func initializeFeedbackWindowIfNeeded() {
        if FeedbackWindow.shared == nil { _ = FeedbackWindow() }
    }

    private static func initializeDebugWindowIfNeeded() {
        if DebugWindow.shared == nil { _ = DebugWindow() }
    }

    private static func initializePermissionsWindowIfNeeded() {
        if PermissionsWindow.shared == nil { _ = PermissionsWindow() }
    }

    @discardableResult
    private static func showSettingsWindowOnFirstLaunchIfNeeded() -> Bool {
        guard !Preferences.settingsWindowShownOnFirstLaunch else { return false }
        showSettingsWindow()
        Preferences.markSettingsWindowShownOnFirstLaunch()
        return true
    }

    static func showPermissionsWindow() {
        initializePermissionsWindowIfNeeded()
        PermissionsWindow.show()
    }

    static func showUi(_ shortcutIndex: Int) {
        showUiOrCycleSelection(shortcutIndex, true)
    }

    @objc static func showUiFromShortcut0() {
        showUi(0)
    }

    static func cycleSelection(_ direction: Direction, allowWrap: Bool = true) {
        (TilesView.scrollView?.documentView as? TilesDocumentView)?.cancelDraggingTimer()
        CursorEvents.resetDeadzone()
        if direction == .up || direction == .down {
            TilesView.navigateUpOrDown(direction, allowWrap: allowWrap)
        } else {
            Windows.cycleSelectedWindowIndex(direction.step(), allowWrap: allowWrap)
        }
    }

    static func previousWindowShortcutWithRepeatingKey() {
        cycleSelection(.trailing)
        KeyRepeatTimer.startRepeatingKeyPreviousWindow()
    }

    private static var lastFocusTime: CFAbsoluteTime = 0
    private static var lastFocusWid: CGWindowID?

    static func focusSelectedWindow(_ selectedWindow: Window?) {
        guard appIsBeingUsed else { return } // already hidden
        guard let selectedWindow else {
            Diagnostics.markSwitchPhase("focusSelectedWindow", extra: "wid=nil")
            Diagnostics.log("KEY", "release ignored: no selected window")
            hideUi(true)
            return
        }
        // Debounce: ignore duplicate fires for the SAME target within 200ms.
        // Ghost fires happen from redundant holdShortcut/flagsChanged handlers.
        // Different targets always pass (legitimate fast switch).
        let now = CFAbsoluteTimeGetCurrent()
        selectedWindow.prepareForFocus()
        let targetWid = selectedWindow.cgWindowId
        if targetWid == nil && !selectedWindow.isWindowlessApp && !Preferences.onlyShowApplications() {
            Diagnostics.markSwitchPhase("focusSelectedWindow", extra: "wid=nil")
            Diagnostics.log("KEY", "release ignored: selected window has no window id \(selectedWindow.debugId ?? "?")")
            hideUi(true)
            return
        }
        if targetWid == sessionSourceWid {
            Diagnostics.markSwitchPhase("focusSelectedWindowNoop", extra: "source wid=\(targetWid ?? 0)")
            Diagnostics.log("KEY", "release ignored: selected source/current window; hide only wid=\(targetWid ?? 0)")
            hideUi(true)
            return
        }
        if now - lastFocusTime < 0.2 && targetWid == lastFocusWid {
            Diagnostics.log("KEY", "DEBOUNCED duplicate focusSelectedWindow (gap=\(Int((now - lastFocusTime) * 1000))ms)")
            hideUi(true)
            return
        }
        let targetIsPar = selectedWindow.isParallelsCoherenceWindow
        let sourceIsPar = App.sessionSourcePid.flatMap { pid in
            Applications.list.first { $0.pid == pid }?.isParallelsCoherence
        } ?? false
        let isParInvolved = targetIsPar || sourceIsPar
        let parCaptureTimeoutMs = RuntimeFlags.thumbnailCaptureFocusSettleGateMs
        let focusCaptureToken = isParInvolved
            ? blockThumbnailCaptures(reason: "par-focus-selected target=#\(targetWid ?? 0)", timeoutMs: parCaptureTimeoutMs)
            : 0
        cancelDelayedDisplay()
        lastFocusTime = now
        lastFocusWid = targetWid
        if let targetWid {
            noteAltTabFocusIntent(targetWid: targetWid)
            if targetWid == sessionSourceWid && Windows.displayableAlternativeCount(excluding: targetWid) > 0 {
                Windows.logPanelOrder("source-target-focus")
            }
            Windows.requestZOrderReview(reason: "alttab-focus-intent", wid: targetWid, fullDelayMs: 250)
        }
        // Click-time live-title check for Parallels Coherence windows.
        // If the panel-build refresh missed an update (or the user
        // navigated OneNote between panel-show and click), this catches
        // the divergence and refreshes before logging the KEY line.
        // Surfaces the "tile said X but live says Y" failure mode.
        if selectedWindow.isParallelsCoherenceWindow,
           let axElement = selectedWindow.axUiElement, let wid = selectedWindow.cgWindowId {
            var titleValue: AnyObject?
            AXUIElementSetMessagingTimeout(axElement, Float(RuntimeFlags.coherenceTitleAxTimeoutMs) / 1000)
            if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let liveTitle = titleValue as? String, !liveTitle.isEmpty,
               liveTitle != selectedWindow.title {
                Diagnostics.log("TITLEMISS", "wid=\(wid) tile-said='\(selectedWindow.title ?? "")' live-at-click='\(liveTitle)'")
                selectedWindow.refreshTitleIfChanged(liveTitle)
            }
        }
        Diagnostics.markSwitchPhase("focusSelectedWindow", extra: "wid=\(targetWid?.description ?? "nil")")
        Diagnostics.log("KEY", "release → focusSelectedWindow target=\(selectedWindow.debugId ?? "nil")")
        Diagnostics.logFrontmostQuick("pre-focus")
        // Light z-order sampling: 5 samples over 1s (not 25 over 5s).
        // Enough to diagnose z-order issues without GPU/CPU churn.
        Diagnostics.sampleZOrderOverTime(label: "focus-\(selectedWindow.cgWindowId ?? 0)", durationMs: 1000, intervalMs: 200)
        // Show the TARGET window's cached content on an overlay at max
        // level. Terminal stays visible regardless of Parallels' re-raise.
        // IOSurface→CGImage conversion via CIContext (GPU, fast).
        // Overlay mode: toggle via defaults write com.lwouis.alt-tab-macos overlayMode -bool true/false
        if FocusOverlay.overlayModeEnabled {
            let targetIsPar = selectedWindow.isParallelsCoherenceWindow
            let sourceIsPar = App.sessionSourcePid.flatMap { pid in
                Applications.list.first { $0.pid == pid }?.isParallelsCoherence
            } ?? false
            if targetIsPar || sourceIsPar {
                FocusOverlay.showTarget(selectedWindow, duration: 1.5)
            } else {
                FocusOverlay.dismiss()
            }
        }
        // For Parallels-involved transitions: raise the target FIRST
        // while the switcher panel (L101) acts as a "curtain" covering
        // everything. The target renders underneath. Then dismiss the
        // panel after a short delay — target is already in place.
        if isParInvolved {
            if MissionControl.state() == .inactive || MissionControl.state() == .showDesktop {
                Diagnostics.markSwitchPhase("preFocus", extra: "par=true")
                selectedWindow.focus()
                Diagnostics.scheduleFocusInvariantChecks(target: selectedWindow, sourceWid: sessionSourceWid, generation: Windows.currentZOrderFocusGeneration(), label: "post-focus par")
                if Preferences.cursorFollowFocus == .always || (
                    Preferences.cursorFollowFocus == .differentScreen && (Spaces.screenSpacesMap.first { $0.value.contains { space in selectedWindow.spaceIds.contains(space) } })?.key != NSScreen.active()?.cachedUuid()) {
                    moveCursorToSelectedWindow(selectedWindow)
                }
            } else {
                PreviewPanel.shared.orderOut(nil)
            }
            scheduleParHideUi(targetWid: targetWid, targetPid: selectedWindow.application.pid, targetTitle: selectedWindow.title, sourceIsPar: sourceIsPar, targetIsPar: targetIsPar, captureToken: focusCaptureToken)
        } else {
            // Non-Parallels: focus FIRST, then dismiss the panel. Prior
            // order called hideUi(true) synchronously (~25-75ms on the
            // event-tap teardown path), so SLPS didn't fire until after
            // the panel had already disappeared and the previous frontmost
            // briefly re-rendered. Reordering pushes SLPS to t=0, hides
            // the panel afterward — the popUpMenu-level TilesPanel keeps
            // the visual curtain up while the target raises beneath it.
            // Same logic the Parallels branch above already relies on.
            if MissionControl.state() == .inactive || MissionControl.state() == .showDesktop {
                Diagnostics.markSwitchPhase("preFocus", extra: "par=false")
                selectedWindow.focus()
                Diagnostics.scheduleFocusInvariantChecks(target: selectedWindow, sourceWid: sessionSourceWid, generation: Windows.currentZOrderFocusGeneration(), label: "post-focus native")
                if Preferences.cursorFollowFocus == .always || (
                    Preferences.cursorFollowFocus == .differentScreen && (Spaces.screenSpacesMap.first { $0.value.contains { space in selectedWindow.spaceIds.contains(space) } })?.key != NSScreen.active()?.cachedUuid()) {
                    moveCursorToSelectedWindow(selectedWindow)
                }
            } else {
                PreviewPanel.shared.orderOut(nil)
            }
            Diagnostics.markSwitchPhase("preHideUi")
            hideUi(true)
        }
    }

    private static func parHideUiDelayMs(sourceIsPar: Bool, targetIsPar: Bool) -> Int {
        if let override = UserDefaults.standard.object(forKey: "parHideUiDelayMs") as? Int { return override }
        if sourceIsPar != targetIsPar { return RuntimeFlags.parCrossBoundaryHideUiDelayMs }
        return RuntimeFlags.parSameBoundaryHideUiDelayMs
    }

    private static func cancelPendingParHide() {
        parHideToken += 1
        parGuestForegroundStates.removeAll()
        if let token = pendingParCaptureGateToken {
            pendingParCaptureGateToken = nil
            releaseThumbnailCaptureGate(token, reason: "cancel-par-hide")
        }
    }

    private static func prepareParGuestForegroundReadiness(token: Int, targetIsPar: Bool, targetTitle: String?) {
        parGuestForegroundStates.removeAll()
        guard RuntimeFlags.parGuestForegroundReadinessEnabled, targetIsPar, Winside.isEnabled,
              let targetTitle, !targetTitle.isEmpty else { return }
        parGuestForegroundStates[token] = ParGuestForegroundState(targetTitle: targetTitle)
    }

    private static func updateParGuestForegroundReadiness(token: Int, now: CFAbsoluteTime) {
        guard var state = parGuestForegroundStates[token] else { return }
        let interval = Double(max(RuntimeFlags.parGuestForegroundPollIntervalMs, 25)) / 1000
        guard !state.probeInFlight, state.lastProbeAt == 0 || now - state.lastProbeAt >= interval else { return }
        state.probeInFlight = true
        state.lastProbeAt = now
        let targetTitle = state.targetTitle
        parGuestForegroundStates[token] = state
        Winside.queryForegroundAsync(label: "readiness target") { foreground in
            DispatchQueue.main.async {
                guard var current = parGuestForegroundStates[token] else { return }
                current.probeInFlight = false
                if let foreground {
                    current.lastHwnd = foreground.0
                    current.lastPid = foreground.1
                    current.lastTitle = foreground.2
                    if Winside.foregroundTitle(foreground.2, matchesTargetTitle: targetTitle) {
                        current.readySince = current.readySince ?? CFAbsoluteTimeGetCurrent()
                    } else {
                        current.readySince = nil
                    }
                } else {
                    current.readySince = nil
                }
                parGuestForegroundStates[token] = current
            }
        }
    }

    private static func parGuestForegroundStatus(token: Int, now: CFAbsoluteTime) -> (ready: Bool, stableMs: Int, requiredMs: Int, title: String) {
        guard let state = parGuestForegroundStates[token] else { return (true, 0, 0, "") }
        let requiredMs = RuntimeFlags.parGuestForegroundStableMs
        let stableMs = state.readySince.map { Int((now - $0) * 1000) } ?? 0
        return (stableMs >= requiredMs, stableMs, requiredMs, state.lastTitle)
    }

    private static func retryParGuestForegroundIfNeeded(token: Int, targetWid: CGWindowID?, now: CFAbsoluteTime, elapsedMs: Int) {
        guard var state = parGuestForegroundStates[token], state.readySince == nil else { return }
        guard !state.setInFlight, state.setAttempts < RuntimeFlags.parGuestForegroundRetryMaxCount else { return }
        let interval = Double(max(RuntimeFlags.parGuestForegroundRetryIntervalMs, RuntimeFlags.parGuestForegroundPollIntervalMs)) / 1000
        guard elapsedMs >= RuntimeFlags.parGuestForegroundPollIntervalMs, state.lastSetAt == 0 || now - state.lastSetAt >= interval else { return }
        state.setInFlight = true
        state.setAttempts += 1
        state.lastSetAt = now
        let attempt = state.setAttempts
        let title = state.targetTitle
        parGuestForegroundStates[token] = state
        Winside.setForegroundForTitleMeasuredAsync(title, label: "readiness-retry wid=\(targetWid ?? 0) attempt=\(attempt)", shouldProceed: {
            token == parHideToken
        }) { result in
            guard var current = parGuestForegroundStates[token] else { return }
            current.setInFlight = false
            parGuestForegroundStates[token] = current
            Diagnostics.log("FOCUS", String(format: "guestForegroundRetryDone wid=%u attempt=%d ok=%@ hwnd=%@ total=%.1fms reason=%@", targetWid ?? 0, attempt, result.ok ? "true" : "false", result.hwnd.map(String.init) ?? "nil", result.elapsedMs, result.reason))
        }
    }

    private static func scheduleParHideUi(targetWid: CGWindowID?, targetPid: pid_t?, targetTitle: String?, sourceIsPar: Bool, targetIsPar: Bool, captureToken preFocusCaptureToken: UInt64 = 0) {
        parHideToken += 1
        let token = parHideToken
        parHideVisualReassertedToken = token
        parHideVisualReassertCount = 0
        parHideVisualReassertAt = 0
        prepareParGuestForegroundReadiness(token: token, targetIsPar: targetIsPar, targetTitle: targetTitle)
        let minDelayMs = parHideUiDelayMs(sourceIsPar: sourceIsPar, targetIsPar: targetIsPar)
        let maxDelayMs = max(minDelayMs, RuntimeFlags.parHideMaxDelayMs)
        let hardMaxDelayMs = targetIsPar && RuntimeFlags.zOrderFixesEnabled ? max(maxDelayMs, RuntimeFlags.parTargetHardMaxDelayMs) : maxDelayMs
        let startedAt = CFAbsoluteTimeGetCurrent()
        let captureTimeoutMs = RuntimeFlags.thumbnailCaptureFocusSettleGateMs
        let captureToken = preFocusCaptureToken > 0 ? preFocusCaptureToken : blockThumbnailCaptures(reason: "par-focus-settle target=#\(targetWid ?? 0)", timeoutMs: captureTimeoutMs)
        pendingParCaptureGateToken = captureToken > 0 ? captureToken : nil
        Diagnostics.markSwitchPhase("parHideScheduled", extra: "\(minDelayMs)-\(maxDelayMs)/\(hardMaxDelayMs)ms sourcePar=\(sourceIsPar) targetPar=\(targetIsPar)")
        logGuestForegroundIfNeeded("parHideScheduled target=#\(targetWid ?? 0) sourcePar=\(sourceIsPar) targetPar=\(targetIsPar)")
        pollParHideUi(token: token, captureToken: captureToken, targetWid: targetWid, targetPid: targetPid, sourceIsPar: sourceIsPar, targetIsPar: targetIsPar, startedAt: startedAt, minDelayMs: minDelayMs, maxDelayMs: maxDelayMs, hardMaxDelayMs: hardMaxDelayMs, readySince: nil, stackSignature: nil, stackReadySince: nil)
    }

    private static func pollParHideUi(token: Int, captureToken: UInt64, targetWid: CGWindowID?, targetPid: pid_t?, sourceIsPar: Bool, targetIsPar: Bool, startedAt: CFAbsoluteTime, minDelayMs: Int, maxDelayMs: Int, hardMaxDelayMs: Int, readySince: CFAbsoluteTime?, stackSignature: String?, stackReadySince: CFAbsoluteTime?) {
        let pollMs = max(10, RuntimeFlags.parHidePollIntervalMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pollMs)) {
            guard appIsBeingUsed && token == parHideToken else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let elapsedMs = Int((now - startedAt) * 1000)
            let stackCount = sourceIsPar && targetIsPar ? RuntimeFlags.parSameBoundaryStackStableWindowCount : 1
            let topRanking = Windows.captureTopZRanking(maxCount: stackCount)
            let topWid = topRanking.first?.wid
            let currentStackSignature = sourceIsPar && targetIsPar ? topRanking.map { "\($0.wid)" }.joined(separator: ",") : nil
            let nextStackReadySince = currentStackSignature == nil ? nil : (currentStackSignature == stackSignature ? (stackReadySince ?? now) : now)
            let stackStableMs = nextStackReadySince.map { Int((now - $0) * 1000) } ?? 0
            let requiredStackStableMs = sourceIsPar && targetIsPar ? RuntimeFlags.parSameBoundaryStackStableMs : 0
            let stackStableEnough = requiredStackStableMs == 0 || stackStableMs >= requiredStackStableMs
            let targetReady = targetWid != nil && topWid == targetWid
            let nextReadySince = targetReady ? (readySince ?? now) : nil
            let stableMs = nextReadySince.map { Int((now - $0) * 1000) } ?? 0
            let requiredStableMs = sourceIsPar && targetIsPar ? RuntimeFlags.parSameBoundaryHideStableMs : RuntimeFlags.parHideStableMs
            let stableEnough = stableMs >= requiredStableMs
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let frontmostReady = !RuntimeFlags.parHideRequiresFrontmost || targetPid == nil || frontPid == targetPid
            updateParGuestForegroundReadiness(token: token, now: now)
            let guest = parGuestForegroundStatus(token: token, now: now)
            let settled = targetReady && stableEnough && frontmostReady && stackStableEnough && guest.ready
            let absoluteMaxDelayMs = targetIsPar ? max(hardMaxDelayMs, RuntimeFlags.parTargetAbsoluteMaxDelayMs) : hardMaxDelayMs
            maybeReassertParallelsTarget(token: token, sourceIsPar: sourceIsPar, targetIsPar: targetIsPar, elapsedMs: elapsedMs, targetReady: targetReady, frontmostReady: frontmostReady, targetWid: targetWid, targetPid: targetPid, frontPid: frontPid)
            retryParGuestForegroundIfNeeded(token: token, targetWid: targetWid, now: now, elapsedMs: elapsedMs)
            guard elapsedMs >= minDelayMs && (settled || elapsedMs >= absoluteMaxDelayMs) else {
                pollParHideUi(token: token, captureToken: captureToken, targetWid: targetWid, targetPid: targetPid, sourceIsPar: sourceIsPar, targetIsPar: targetIsPar, startedAt: startedAt, minDelayMs: minDelayMs, maxDelayMs: maxDelayMs, hardMaxDelayMs: hardMaxDelayMs, readySince: nextReadySince, stackSignature: currentStackSignature, stackReadySince: nextStackReadySince)
                return
            }
            Diagnostics.markSwitchPhase("parHideNow", extra: "\(elapsedMs)ms ready=\(targetReady) stable=\(stableMs)/\(requiredStableMs)ms stack=\(stackStableMs)/\(requiredStackStableMs)ms front=\(frontmostReady) target=#\(targetWid ?? 0) top=#\(topWid ?? 0) frontPid=\(frontPid ?? 0) targetPid=\(targetPid ?? 0) hardMax=\(hardMaxDelayMs) absoluteMax=\(absoluteMaxDelayMs) guest=\(guest.ready) guestStable=\(guest.stableMs)/\(guest.requiredMs)ms guestTitle='\(guest.title.prefix(40))'")
            logGuestForegroundIfNeeded("parHideNow target=#\(targetWid ?? 0) top=#\(topWid ?? 0) front=\(frontmostReady)")
            if pendingParCaptureGateToken == captureToken {
                pendingParCaptureGateToken = nil
            }
            parGuestForegroundStates[token] = nil
            hideUi(true)
            if settled {
                releaseThumbnailCaptureGate(captureToken, reason: "par-hide-settled")
            } else {
                Diagnostics.log("CAPTURE", "thumbnail gate retained after par hide token=\(captureToken) reason=not-settled")
            }
        }
    }

    private static func logGuestForegroundIfNeeded(_ label: String) {
        guard RuntimeFlags.parGuestForegroundDiagnosticsEnabled, Winside.isEnabled else { return }
        Winside.queryForegroundAsync(label: label)
    }

    private static func maybeReassertParallelsTarget(token: Int, sourceIsPar: Bool, targetIsPar: Bool, elapsedMs: Int, targetReady: Bool, frontmostReady: Bool, targetWid: CGWindowID?, targetPid: pid_t?, frontPid: pid_t?) {
        guard targetIsPar && RuntimeFlags.zOrderFixesEnabled else { return }
        let reassertDelayMs = sourceIsPar && targetIsPar ? RuntimeFlags.parSameBoundaryReassertDelayMs : RuntimeFlags.parTargetReassertDelayMs
        guard elapsedMs >= max(reassertDelayMs, RuntimeFlags.parHidePollIntervalMs) else { return }
        guard let targetWid, let targetPid else { return }
        if !frontmostReady {
            Windows.restoreFrontmostToTarget(targetWid: targetWid, targetPid: targetPid, frontPid: frontPid ?? -1, source: "PARHIDE")
        } else if !targetReady && shouldReassertParallelsVisualTarget(token: token, elapsedMs: elapsedMs) {
            Windows.restoreFrontmostToTarget(targetWid: targetWid, targetPid: targetPid, frontPid: frontPid ?? -1, source: "PARHIDE_VISUAL", bypassThrottle: true)
        }
    }

    private static func shouldReassertParallelsVisualTarget(token: Int, elapsedMs: Int) -> Bool {
        guard elapsedMs >= RuntimeFlags.parTargetVisualReassertDelayMs else { return false }
        if parHideVisualReassertedToken != token {
            parHideVisualReassertedToken = token
            parHideVisualReassertCount = 0
            parHideVisualReassertAt = 0
        }
        guard parHideVisualReassertCount < RuntimeFlags.parTargetVisualReassertMaxCount else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let interval = Double(max(RuntimeFlags.parTargetVisualReassertIntervalMs, RuntimeFlags.parHidePollIntervalMs)) / 1000
        guard parHideVisualReassertAt == 0 || now - parHideVisualReassertAt >= interval else { return false }
        parHideVisualReassertCount += 1
        parHideVisualReassertAt = now
        return true
    }

    private static func topVisibleAppWindowId() -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let blocklist: Set<String> = ["Window Server", "Control Center", "Dock", "AltTab", "Notification Center", "SystemUIServer", "Spotlight", "Menubar", "Wallpaper", "CursorUIViewService", "UserNotificationCenter", "LocalAuthenticationRemoteService"]
        for row in info {
            let owner = (row[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            if ((row[kCGWindowLayer as String] as? Int) ?? 0) != 0 { continue }
            if ((row[kCGWindowAlpha as String] as? Double) ?? 1) < 0.1 { continue }
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, width >= 40,
                  let height = bounds["Height"] as? Double, height >= 40,
                  let wid = row[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(wid)
        }
        return nil
    }

    private static func cancelDelayedDisplay() {
        delayedDisplayToken += 1
        delayedDisplayScheduled = 0
    }

    static func moveCursorToSelectedWindow(_ window: Window) {
        let referenceWindow = window.referenceWindowForTabbedWindow()
        guard let position = referenceWindow?.position, let size = referenceWindow?.size else { return }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        CGWarpMouseCursorPosition(point)
    }

    static func refreshOpenUiAfterExternalEvent(_ windowsToScreenshot: [Window], windowRemoved: Bool = false, source: RefreshCausedBy = .refreshUiAfterExternalEvent) {
        Windows.refreshThumbnailsAsync(windowsToScreenshot, source, windowRemoved: windowRemoved)
        refreshOpenUiThrottler.throttleOrProceed {
            guard appIsBeingUsed else { return }
            if !Windows.updatesBeforeShowing() { hideUi(); return }
            refreshUi(true)
        }
    }

    static func refreshUi(_ preserveScrollPosition: Bool = false) {
        guard appIsBeingUsed else { return }
        let preservedScrollOrigin = preserveScrollPosition ? TilesView.currentScrollOrigin() : nil
        Windows.updateSelectedWindow()
        guard appIsBeingUsed else { return }
        TilesPanel.shared.updateContents(preservedScrollOrigin)
        guard appIsBeingUsed else { return }
        Windows.voiceOverWindow() // at this point TileViews are assigned to the window, and ready
        guard appIsBeingUsed else { return }
        Windows.previewSelectedWindowIfNeeded()
        guard appIsBeingUsed else { return }
        Applications.refreshBadgesAsync()
    }

    static func showUiOrCycleSelection(_ shortcutIndex: Int, _ forceDoNothingOnRelease_: Bool) {
        let showStartedAt = CFAbsoluteTimeGetCurrent()
        cancelPendingParHide()
        clearFocusTargetSuppression()
        forceDoNothingOnRelease = forceDoNothingOnRelease_
        Logger.debug { "isFirstSummon:\(isFirstSummon) shortcutIndex:\(shortcutIndex)" }
        let startingNewSession = !appIsBeingUsed
        // Capture the REAL source app before the TilesPanel shows and possibly
        // steals key-window status. Needed for the Parallels Coherence outbound
        // fix — otherwise `Applications.frontmostPid` reads as AltTab's own pid
        // by the time `Window.focus()` runs.
        if !appIsBeingUsed {
            lastFocusTime = 0
            lastFocusWid = nil
            // Overlay stays at L50 (below switcher's L101) — no need to
            // dismiss. Switcher draws above, overlay covers Parallels below.
            Diagnostics.log("SESSION", "new session shortcutIndex=\(shortcutIndex)")
            Diagnostics.logFrontmostSignals("session-start pre")
            Diagnostics.logTrackedRecency("session-start pre")
            // Prefer a live source of truth at session start. Some apps
            // (Terminal in particular) can visually raise a same-process
            // sibling without AltTab receiving the AX focus notification, so
            // cached `Application.focusedWindow` can drift behind WindowServer.
            // Sync from WindowServer/AX before building the list.
            //
            // Bug that motivated this order: lastFocusedTargetWid is
            // only set by our Parallels-involved paths. After a pure
            // mac→mac AltTab, the Par-era wid lingered; using it as
            // "current source" at next session start caused normalize
            // to promote the wrong window to position 0.
            let newSourceWid: CGWindowID? = {
                if let wid = Windows.syncFocusOrderWithLiveFrontmostWindow() {
                    return wid
                }
                if let pid = Applications.frontmostPid,
                   let app = (Applications.list.first { $0.pid == pid }),
                   let focused = app.focusedWindow {
                    return focused.cgWindowId
                }
                if let wid = lastFocusedTargetWid,
                   Windows.list.contains(where: { $0.cgWindowId == wid }) {
                    return wid
                }
                return nil
            }()
            let recencyPreviousWid = Windows.nextDisplayedFocusWindowId(after: newSourceWid)
            if newSourceWid != sessionSourceWid {
                previousSessionSourceWid = preferredPreviousWidAtSessionStart(currentWid: newSourceWid, recencyPreviousWid: recencyPreviousWid)
                sessionSourceWid = newSourceWid
                Windows.normalizeFocusOrderAtSessionStart(
                    currentWid: sessionSourceWid,
                    previousWid: previousSessionSourceWid)
            }
            Diagnostics.logFrontmostSignals("session-start post")
            Diagnostics.logTrackedRecency("session-start post")
        }
        appIsBeingUsed = true
        startInputCaptureWatchdog(resetCaptureAge: startingNewSession)
        UsageStats.recordTrigger(shortcutIndex)
        if isFirstSummon || shortcutIndex != App.shortcutIndex {
            let beforeScreenAt = CFAbsoluteTimeGetCurrent()
            NSScreen.updatePreferred()
            let afterScreenAt = CFAbsoluteTimeGetCurrent()
            if isVeryFirstSummon {
                Windows.sortByLevel(shortcutIndex)
                isVeryFirstSummon = false
                if startingNewSession {
                    previousSessionSourceWid = preferredPreviousWidAtSessionStart(
                        currentWid: sessionSourceWid,
                        recencyPreviousWid: Windows.nextDisplayedFocusWindowId(after: sessionSourceWid))
                    Windows.normalizeFocusOrderAtSessionStart(
                        currentWid: sessionSourceWid,
                        previousWid: previousSessionSourceWid)
                }
            }
            let afterInitialSortAt = CFAbsoluteTimeGetCurrent()
            isFirstSummon = false
            App.shortcutIndex = shortcutIndex
            let shouldStartInSearchMode = Preferences.shortcutStyle == .searchOnRelease
            TilesView.startSearchSession(shouldStartInSearchMode)
            if shouldStartInSearchMode {
                forceDoNothingOnRelease = true
            }
            let afterSearchAt = CFAbsoluteTimeGetCurrent()
            if !Windows.updatesBeforeShowing() { hideUi(); return }
            let afterWindowsAt = CFAbsoluteTimeGetCurrent()
            Windows.setInitialSelectedAndHoveredWindowIndex()
            let afterSelectionAt = CFAbsoluteTimeGetCurrent()
            // Pre-capture ONLY the selected window at retina. Multiple
            // parallel CGWindowListCreateImage calls serialize on the
            // window server lock — 4 parallel = 28s total. One = 1-2s.
            if let selected = Windows.selectedWindow(),
               let wid = selected.cgWindowId,
               let pos = selected.position, let sz = selected.size {
                if #available(macOS 14.0, *) {
                    FocusOverlay.preCapture(wid: wid, position: pos, size: sz)
                }
            }
            let afterPreCaptureAt = CFAbsoluteTimeGetCurrent()
            // Use longer delay when source is a Parallels Coherence window
            // to allow fast-switch without showing the panel (reduces flicker).
            // defaults write com.lwouis.alt-tab-macos coherenceDisplayDelay -int 500
            // Use coherence delay when EITHER source or any top-2 target
            // is a Parallels window. Parallels transitions are visually
            // noisy, so suppress the panel for fast switches in both
            // directions (Par→mac AND mac→Par).
            let isCoherenceSource = App.sessionSourcePid.flatMap { pid in
                Applications.list.first { $0.pid == pid }?.isParallelsCoherence
            } ?? false
            // Check only the fast-switch target (position 1 = what a quick
            // alt-tab selects). Don't check top 3 — that triggers coherence
            // delay for ALL sessions when any Parallels window is recent.
            let fastSwitchTarget = Windows.list
                .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
                .dropFirst() // skip position 0 (current)
                .first
            let isCoherenceTarget = fastSwitchTarget?.application.isParallelsCoherence ?? false
            let isCoherenceInvolved = isCoherenceSource || isCoherenceTarget
            let isCoherenceSameBoundary = isCoherenceSource && isCoherenceTarget
            let afterTargetAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("REFRESH", String(format: "show prep: screen=%.1fms initialSort=%.1fms search=%.1fms windows=%.1fms selection=%.1fms precapture=%.1fms target=%.1fms total=%.1fms", (afterScreenAt - beforeScreenAt) * 1000, (afterInitialSortAt - afterScreenAt) * 1000, (afterSearchAt - afterInitialSortAt) * 1000, (afterWindowsAt - afterSearchAt) * 1000, (afterSelectionAt - afterWindowsAt) * 1000, (afterPreCaptureAt - afterSelectionAt) * 1000, (afterTargetAt - afterPreCaptureAt) * 1000, (afterTargetAt - showStartedAt) * 1000))
            let coherenceMs = isCoherenceSameBoundary ? RuntimeFlags.parSameBoundaryDisplayDelayMs : UserDefaults.standard.integer(forKey: "coherenceDisplayDelay")
            let delay: DispatchTimeInterval = isCoherenceInvolved
                ? .milliseconds(coherenceMs)
                : Preferences.windowDisplayDelay
            Diagnostics.log("PANEL", "display delay: \(isCoherenceInvolved ? "\(coherenceMs)ms (coherence src=\(isCoherenceSource) tgt=\(isCoherenceTarget) same=\(isCoherenceSameBoundary))" : "\(Preferences.windowDisplayDelay) (normal)")")
            if delay == .milliseconds(0) {
                buildUiAndShowPanel()
            } else {
                delayedDisplayScheduled += 1
                let token = delayedDisplayToken
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay) { () -> () in
                    guard token == delayedDisplayToken else { return }
                    if delayedDisplayScheduled == 1 {
                        buildUiAndShowPanel()
                    }
                    delayedDisplayScheduled -= 1
                }
            }
        } else {
            cycleSelection(.leading)
            KeyRepeatTimer.startRepeatingKeyNextWindow()
        }
    }

    static func buildUiAndShowPanel() {
        guard appIsBeingUsed else { return }
        Appearance.update()
        guard appIsBeingUsed else { return }
        refreshUi()
        guard appIsBeingUsed else { return }
        Diagnostics.log("PANEL", "showPanel (window count=\(Windows.list.count))")
        TilesPanel.shared.show()
        Windows.previewSelectedWindowIfNeeded()
        if TilesView.isSearchEditing {
            TilesView.enableSearchEditing()
        }
        KeyRepeatTimer.startRepeatingKeyNextWindow()
        TilesView.refreshVisibleThumbnailsIfNeeded("show", force: true)
        TilesView.startVisibleThumbnailRefreshTimer()
        let prioritized = Set(TilesView.visibleWindowsForThumbnailRefresh().compactMap { $0.cgWindowId })
        let deferred = Windows.list.filter { window in
            guard let wid = window.cgWindowId else { return false }
            return !prioritized.contains(wid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
            guard appIsBeingUsed else { return }
            Windows.refreshThumbnailsAsync(deferred, .refreshOnlyThumbnailsAfterShowUi)
        }
    }

    static func checkIfShortcutsShouldBeDisabled(_ activeWindow: Window?, _ activeApp: Application?) {
        let app = activeWindow?.application ?? activeApp!
        let shortcutsShouldBeDisabled = Preferences.exceptions.contains { exception in
            if let id = app.bundleIdentifier {
                return id.hasPrefix(exception.bundleIdentifier) &&
                    (exception.ignore == .always || (exception.ignore == .whenFullscreen && (activeWindow?.isFullscreen ?? false)))
            }
            return false
        }
        KeyboardEvents.toggleGlobalShortcuts(shortcutsShouldBeDisabled)
        if shortcutsShouldBeDisabled && appIsBeingUsed {
            hideUi()
        }
    }

    static func continueAppLaunchAfterPermissionsAreGranted() {
        Logger.info { "System permissions are granted; continuing launch" }
        BackgroundWork.start()
        NSScreen.updatePreferred()
        Appearance.update()
        TilesPanel.updateMaxPossibleThumbnailSize()
        TilesPanel.updateMaxPossibleAppIconSize()
        Menubar.initialize()
        MainMenu.create()
        _ = TilesPanel()
        _ = PreviewPanel()
        Spaces.refresh()
        Screens.refresh()
        Windows.startZOrderCache()
        SpacesEvents.observe()
        ScreensEvents.observe()
        SystemAppearanceEvents.observe()
        SystemScrollerStyleEvents.observe()
        InputSourceEvents.observe()
        Applications.initialDiscovery()
        KeyboardEvents.addEventHandlers()
        CursorEvents.observe()
        TrackpadEvents.observe()
        CliEvents.observe()
        PreferencesEvents.initialize()
        BenchmarkRunner.startIfNeeded()
        showSettingsWindowOnFirstLaunchIfNeeded()
        if pendingShowSettingsWindow {
            pendingShowSettingsWindow = false
            showSettingsWindow()
        }
        #if DEBUG
//            App.showSettingsWindow()
        #endif
        UsageStats.prune()
        BackgroundThumbnailRefresher.shared.start()
        Logger.info { "Finished launching AltTab" }
    }
}

extension App: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Ignore SIGPIPE process-wide. Without this, any write to a
        // half-closed socket (e.g. the Winside TCP socket when the
        // guest helper has hung) raises SIGPIPE → silent process
        // death with NO crash report. We observed exactly this:
        // AltTab vanished mid-alt-tab leaving the user without a
        // window switcher and no diagnostic. Per-socket SO_NOSIGPIPE
        // is also set defensively, but this catches any other
        // unprotected write (NSPipe drains, prlctl IO, etc).
        signal(SIGPIPE, SIG_IGN)
        App.appCenterDelegate = AppCenterCrash()
        App.shared.disableRelaunchOnLogin()
        Logger.initialize()
        Logger.info { "Launching AltTab \(App.version)" }
        Diagnostics.log("INIT", "AltTab \(App.version) launched (custom build with diagnostics)")
        Diagnostics.startContinuousMonitoring()
        // Auto-run profiler if `runProfilerAtLaunch` is set in defaults.
        // Clears the flag immediately so a crash mid-run doesn't loop.
        // 8s settle delay ensures Windows.list has been populated by
        // the initial AX scan before we start picking targets.
        if UserDefaults.standard.bool(forKey: "runProfilerAtLaunch") {
            UserDefaults.standard.set(false, forKey: "runProfilerAtLaunch")
            // Optional override: `defaults write com.lwouis.alt-tab-macos
            // profilerDurationSeconds -int 180` for longer runs / better
            // statistical confidence. Default 60s gives ~21 attempts;
            // 180s gives ~60 attempts (~3% precision on bounce rate).
            let dur = UserDefaults.standard.object(forKey: "profilerDurationSeconds") as? Int ?? 60
            Diagnostics.log("PROFILER", "runProfilerAtLaunch=true; scheduling \(dur)s run in 8s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                Profiler.run(durationSeconds: TimeInterval(dur))
            }
        }
        // Phase 3 IPC: launch the Windows-side TCP helper (in the
        // Parallels guest) if the user has it enabled. Async — does
        // not block app launch. Default ON.
        Winside.startIfNeeded()
        if FocusOverlay.overlayModeEnabled {
            FocusOverlay.createPersistentOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if #available(macOS 14.0, *) {
                    FocusOverlay.startBackgroundRefresh()
                }
            }
        }
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
        #endif
        #if !DEBUG
        PFMoveToApplicationsFolderIfNecessary()
        #endif
        // Global mouse click monitor: tracks clicks to distinguish
        // user-initiated window activations from Parallels' automatic
        // re-activation during the focus guard period.
        // REGISTER-ONCE GUARD: empirically `[DIAG MOUSE]` was firing
        // twice per click — symptom of either an inadvertent double
        // call to applicationDidFinishLaunching or external HID
        // duplication. The guard ensures only the first registration
        // wins and logs the duplicate so it's diagnosable.
        if App.globalClickMonitorRegistered {
            Diagnostics.log("INIT", "duplicate addGlobalMonitorForEvents call suppressed")
        } else {
            App.globalClickMonitorRegistered = true
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
                let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
                let isUp = event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp
                let button = event.type == .leftMouseDown || event.type == .leftMouseUp ? "left" : (event.type == .rightMouseDown || event.type == .rightMouseUp ? "right" : "other")
                let action = isDown ? "down" : "up"
                // Log click target: find topmost window at cursor position
                let pt = NSEvent.mouseLocation
                let screenHeight = NSScreen.main?.frame.height ?? 0
                let cgPoint = CGPoint(x: pt.x, y: screenHeight - pt.y)
                if Windows.shouldIgnoreSyntheticFocusClick(eventTimestamp: event.timestamp) {
                    Diagnostics.log("MOUSE", String(format: "ignored synthetic focus %@ %@ at (%d,%d) ts=%.3f", button, action, Int(cgPoint.x), Int(cgPoint.y), event.timestamp))
                    return
                }
                Windows.noteGlobalMouseButtonEvent(isDown: isDown, isUp: isUp)
                if isDown {
                    Windows.lastMouseClickTime = CFAbsoluteTimeGetCurrent()
                }
                let skipOwners: Set<String> = [
                    "Window Server", "Control Center", "Dock", "AltTab",
                    "Notification Center", "SystemUIServer", "Spotlight",
                    "Menubar", "Wallpaper", "CursorUIViewService", "UserNotificationCenter",
                    "LocalAuthenticationRemoteService",
                ]
                if isDown || isUp, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                    var clickedWindow = false
                    for w in list {
                        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
                        if skipOwners.contains(owner) { continue }
                        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
                        if alpha < 0.1 { continue }
                        guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { continue }
                        let rect = CGRect(x: x, y: y, width: width, height: height)
                        if rect.contains(cgPoint) {
                            clickedWindow = true
                            let name = (w[kCGWindowName as String] as? String) ?? ""
                            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
                            let ownerPid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
                            let short = name.isEmpty ? owner : "\(owner):\(name.prefix(30))"
                            if isDown {
                                Windows.lastMouseClickWid = CGWindowID(wid)
                                Windows.lastMouseClickPid = ownerPid
                                Windows.lastMouseClickOwner = owner
                                Windows.requestZOrderTopReview(reason: "mouse-down", wid: CGWindowID(wid))
                                // CRITICAL: when the user clicks a window
                                // belonging to a DIFFERENT app than the
                                // current AltTab focus target, release
                                // the guard. Without this,
                                // diagnoseFrontmostMismatch sees "target
                                // at z0 but frontmost-app is different"
                                // and fires SLPS to restore the old
                                // target — fighting the user's click and
                                // making it impossible to switch apps
                                // by clicking. The guard's purpose is
                                // to defend against silent self-
                                // activation; an explicit user click is
                                // not silent.
                                if let target = Windows.altTabFocusTarget,
                                   target.application.pid != ownerPid {
                                    Diagnostics.log("GUARD",
                                        "released by user click: clicked pid=\(ownerPid) (\(short.prefix(30))) ≠ target pid=\(target.application.pid)")
                                    Windows.altTabFocusTarget = nil
                                    Windows.altTabFocusTargetUntil = 0
                                    Windows.recentZOrderIntents.removeAll()
                                }
                                Windows.releaseZOrderEnforcementForUserClick(wid: CGWindowID(wid), pid: ownerPid, label: short)
                            } else {
                                Windows.requestZOrderTopReview(reason: "mouse-up", wid: CGWindowID(wid))
                            }
                            Diagnostics.log("MOUSE", "\(button) \(action) at (\(Int(cgPoint.x)),\(Int(cgPoint.y))) → wid=\(wid) pid=\(ownerPid) \(short)")
                            // CLICKMISROUTE: when the click resolved to a wid that
                            // is NOT our most recent AltTab focus target, the user
                            // likely clicked expecting the target window but hit
                            // something else (a stealer at z0, a bouncing sibling,
                            // or just stale focus). We suppress when there's no
                            // recent target (>5s since last focus call) so plain
                            // user-clicking on whatever isn't flagged as misroute.
                            if isDown,
                               let recentTarget = App.lastFocusedTargetWid,
                               let recentTargetTime = App.lastFocusedTargetTime,
                               CFAbsoluteTimeGetCurrent() - recentTargetTime < 5.0,
                               CGWindowID(wid) != recentTarget,
                               list.contains(where: { candidate in
                                   guard let targetWid = candidate[kCGWindowNumber as String] as? Int,
                                         CGWindowID(targetWid) == recentTarget,
                                         let targetBounds = candidate[kCGWindowBounds as String] as? [String: Any],
                                         let targetX = targetBounds["X"] as? Double,
                                         let targetY = targetBounds["Y"] as? Double,
                                         let targetWidth = targetBounds["Width"] as? Double,
                                         let targetHeight = targetBounds["Height"] as? Double else { return false }
                                   return CGRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight).contains(cgPoint)
                               }) {
                                let ageMs = Int((CFAbsoluteTimeGetCurrent() - recentTargetTime) * 1000)
                                let recentTargetPid = App.lastFocusedTargetPid ?? 0
                                let isAppMismatch = (recentTargetPid != 0 && ownerPid != recentTargetPid)
                                let kind = isAppMismatch ? "APP-MISMATCH" : "WINDOW-MISMATCH"
                                Diagnostics.log("CLICKMISROUTE",
                                    "[\(kind)] click→wid=\(wid) pid=\(ownerPid) (\(short.prefix(40))) but AltTab target wid=\(recentTarget) pid=\(recentTargetPid) (\(ageMs)ms ago)")
                            }
                            // CLICKAFTER: schedule a +200ms probe of where
                            // input is actually routed. If frontmost-app's
                            // pid differs from the click's pid at +200ms,
                            // the user's typing in the next ~hundred-ms
                            // would land in the wrong app. This is the
                            // diagnostic that catches "I clicked OneNote
                            // but my keystrokes go to Safari" — clicks
                            // resolve correctly via WindowServer, but a
                            // background app self-activation between
                            // click and keystroke routes input elsewhere.
                            if isDown && Diagnostics.shouldLog("CLICKAFTER") {
                                let clickedWid = CGWindowID(wid)
                                let clickedPid = ownerPid
                                let clickedShort = short
                                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                                    let nsApp = NSWorkspace.shared.frontmostApplication
                                    let frontPid = nsApp?.processIdentifier ?? -1
                                    let frontName = nsApp?.localizedName ?? "?"
                                    guard frontPid != clickedPid else { return }
                                    guard !Windows.isTransientSystemFrontmost(pid: frontPid) else {
                                        Diagnostics.log("CLICKAFTER",
                                            "+200ms after click on wid=\(clickedWid) pid=\(clickedPid) (\(clickedShort.prefix(30))) → transient frontmost is pid=\(frontPid) \(frontName); ignoring input-route mismatch.")
                                        return
                                    }
                                    BackgroundWork.accessibilityCommandsQueue.addOperation {
                                        var axFocusedWid: CGWindowID = 0
                                        let appRef = AXUIElementCreateApplication(frontPid)
                                        var focusedValue: AnyObject?
                                        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
                                           let windowRef = focusedValue {
                                            var w: CGWindowID = 0
                                            if _AXUIElementGetWindow(windowRef as! AXUIElement, &w) == .success {
                                                axFocusedWid = w
                                            }
                                        }
                                        Diagnostics.log("CLICKAFTER",
                                            "+200ms after click on wid=\(clickedWid) pid=\(clickedPid) (\(clickedShort.prefix(30))) → frontmost is pid=\(frontPid) \(frontName) axFoc=#\(axFocusedWid). Input would route to a DIFFERENT app than the user clicked.")
                                        DispatchQueue.main.async {
                                            Windows.repairClickAfterMismatch(clickedWid: clickedWid, clickedPid: clickedPid, frontPid: pid_t(frontPid), frontName: frontName)
                                        }
                                    }
                                }
                            }
                            break
                        }
                    }
                    if !clickedWindow {
                        if isDown {
                            Windows.requestZOrderReview(reason: "mouse-down-unknown", fullDelayMs: 500)
                        } else {
                            Windows.requestZOrderTopReview(reason: "mouse-up-unknown")
                        }
                    }
                } else {
                    if isDown {
                        Windows.requestZOrderReview(reason: "mouse-down-unknown", fullDelayMs: 500)
                    } else if isUp {
                        Windows.requestZOrderTopReview(reason: "mouse-up-unknown")
                    }
                    Diagnostics.log("MOUSE", "\(button) \(action) at (\(Int(cgPoint.x)),\(Int(cgPoint.y)))")
                }
            }
        }
        AXUIElement.setGlobalTimeout()
        Preferences.initialize()
        BackgroundWork.preStart()
        SystemPermissions.ensurePermissionsAreGranted()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        App.showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // symbolic hotkeys state persist after the app is quit; we restore this shortcut before quitting
        setNativeCommandTabEnabled(true)
        // Tell the Windows-side helper to terminate so we don't leave a
        // dangling TCP listener when AltTab quits.
        Windows.stopZOrderCache()
        Winside.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Logger.info { "" }
        makeSureAllCapturesAreFinished()
        return .terminateNow
    }
}

enum RefreshCausedBy {
    case refreshVisibleThumbnailsAfterShowUi
    case refreshOnlyThumbnailsAfterShowUi
    case refreshUiAfterExternalEvent
    case screenParametersChanged
    /// Driven by BackgroundThumbnailRefresher's tick loop while the panel
    /// is closed. Per-window, off-main, low-pri.
    case backgroundPeriodic

    var requiresOpenPanel: Bool {
        self == .refreshVisibleThumbnailsAfterShowUi || self == .refreshOnlyThumbnailsAfterShowUi
    }
}
