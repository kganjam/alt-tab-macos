import Cocoa
import ScreenCaptureKit.SCShareableContent

// macOS has some privacy restrictions. The user needs to grant certain permissions, app by app, in System Preferences > Security & Privacy
class SystemPermissions {
    static var preStartupPermissionsPassed = false
    private static var timer: DispatchSourceTimer!
    private static var timerIsFrequent = false

    static func ensurePermissionsAreGranted() {
        timer = DispatchSource.makeTimerSource(queue: BackgroundWork.permissionsCheckOnTimerQueue.strongUnderlyingQueue)
        timer.setEventHandler(handler: checkPermissionsOnTimer)
        setImmediateTimer()
        timer.resume()
        startStuckAuthPopupWatcher()
    }

    // MARK: - Stuck-popup watcher
    //
    // Background: when AltTab's TCC entries are in a fragmented state
    // (multiple stale code-signature hashes, or cleared mid-launch), tccd
    // can queue many "AltTab would like to control your computer using
    // accessibility features" prompts via UserNotificationCenter. Each
    // prompt is a separate window, and they pile up because the user
    // can't dismiss them fast enough — visible as 50–90 stacked dialogs
    // intercepting clicks. The right long-term fix is upstream (don't
    // queue them in the first place). This watcher is the safety net:
    // if more than `flushStuckAuthPopupsThreshold` UserNotificationCenter
    // windows are onscreen, kill the daemons. macOS respawns them with
    // an empty queue. Other apps' pending prompts get cleared too, but
    // those clients re-request when they next hit a TCC API, so the
    // user only loses an immediate request — not a granted permission.
    private static var stuckPopupTimer: DispatchSourceTimer?

    static var flushStuckAuthPopupsThreshold: Int {
        // 0 = disabled; otherwise auto-flush when count > threshold
        let v = UserDefaults.standard.object(forKey: "flushStuckAuthPopupsThreshold") as? Int
        return v ?? 1
    }

    static func startStuckAuthPopupWatcher() {
        guard stuckPopupTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: BackgroundWork.permissionsCheckOnTimerQueue.strongUnderlyingQueue)
        t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        t.setEventHandler {
            let n = countUserNotificationCenterWindows()
            let threshold = flushStuckAuthPopupsThreshold
            if threshold > 0 && n > threshold {
                Diagnostics.log("AUTHCHECK", "stuck-popup detection: \(n) UserNotificationCenter windows on screen (> threshold \(threshold)); flushing")
                Logger.error { "Detected \(n) stuck auth popups; flushing UserNotificationCenter" }
                flushStuckAuthPopups()
            } else if n >= 1 {
                Diagnostics.log("AUTHCHECK", "UserNotificationCenter windows: \(n) (threshold=\(threshold))")
            }
        }
        t.resume()
        stuckPopupTimer = t
    }

    static func countUserNotificationCenterWindows() -> Int {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return info.reduce(0) { count, w in
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            return count + (owner == "UserNotificationCenter" ? 1 : 0)
        }
    }

    static func flushStuckAuthPopups() {
        // Use the older `launchedProcess` API; the project's
        // MACOSX_DEPLOYMENT_TARGET is 10.12 which predates `Process.run()`.
        Process.launchedProcess(launchPath: "/usr/bin/killall",
                                arguments: ["UserNotificationCenter", "usernotificationsd"])
    }

    private static func checkPermissionsOnTimer() {
        AccessibilityPermission.update()
        let isPermissionsWindowVisible = PermissionsWindow.shared?.isVisible ?? false
        if !preStartupPermissionsPassed || isPermissionsWindowVisible {
            ScreenRecordingPermission.update()
        }
        Logger.debug { "accessibility:\(AccessibilityPermission.status) screenRecording:\(ScreenRecordingPermission.status)" }
        if !preStartupPermissionsPassed {
            checkPermissionsPreStartup()
        } else {
            checkPermissionsPostStartup()
            if isPermissionsWindowVisible && !timerIsFrequent {
                setFrequentTimer()
            } else if !isPermissionsWindowVisible && timerIsFrequent {
                setInfrequentTimer()
            }
        }
        DispatchQueue.main.async {
            Menubar.togglePermissionCallout(ScreenRecordingPermission.status != .granted)
            if PermissionsWindow.shared != nil {
                PermissionsWindow.updatePermissionViews()
            }
        }
    }

    private static func checkPermissionsPreStartup() {
        if AccessibilityPermission.status != .notGranted && ScreenRecordingPermission.status != .notGranted {
            DispatchQueue.main.async {
                preStartupPermissionsPassed = true
                PermissionsWindow.shared?.close()
                setInfrequentTimer()
                App.continueAppLaunchAfterPermissionsAreGranted()
            }
        } else {
            DispatchQueue.main.async {
                App.showPermissionsWindow()
            }
            // Re-arm the timer so we keep polling for the permission flip.
            // Original code left the timer at `.never` after a single
            // immediate fire — meaning if the very first AX check returned
            // "not granted" (or, post-timeout-fix, returned the lastKnown
            // fallback), AltTab would silently never re-check, the
            // PermissionsWindow would sit there forever, and Cmd-Tab would
            // never start working even after the user grants. Schedule
            // a 1s follow-up so the next tick can pick up a granted state.
            setShortRetryTimer()
        }
    }

    private static func setShortRetryTimer() {
        timerIsFrequent = false
        timer.schedule(deadline: .now() + 1, repeating: .never, leeway: .milliseconds(500))
    }

    private static func checkPermissionsPostStartup() {
        if AccessibilityPermission.status == .notGranted {
            Logger.error { "Accessibility permission revoked while AltTab was running; restarting" }
            DispatchQueue.main.async { App.restart() }
        }
    }

    static func setInfrequentTimer() {
        timerIsFrequent = false
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
    }

    static func setFrequentTimer() {
        timerIsFrequent = true
        timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(500))
    }

    private static func setImmediateTimer() {
        timerIsFrequent = false
        timer.schedule(deadline: .now(), repeating: .never, leeway: .never)
    }
}

class AccessibilityPermission {
    static var status = PermissionStatus.notGranted
    // Last-known status, used as a fallback when the AX trust check
    // hangs (see `detect`). On a fresh process this starts at
    // `.notGranted`; once we successfully probe a "granted" result, we
    // remember it and serve it on subsequent timeouts so init
    // (continueAppLaunchAfterPermissionsAreGranted) doesn't deadlock.
    private static var lastKnownStatus: PermissionStatus = .notGranted

    @discardableResult
    static func update() -> PermissionStatus {
        status = detect()
        return status
    }

    private static func detect() -> PermissionStatus {
        // AXIsProcessTrustedWithOptions(prompt:false) is documented as
        // a quick local check, but in practice (observed 2026-05-08)
        // can hang indefinitely against a tccd that is mid-cache-flush
        // — e.g. right after `tccutil reset` + `notifyutil` storms or
        // a tccd kill. Because the permissions timer was scheduled
        // single-shot (`repeating: .never`) and only re-armed *after*
        // a successful check, a single hung call wedged init: the
        // hotkey was never registered and Cmd-Tab silently did nothing.
        // Wrap the call in the same `runWithTimeout` pattern we
        // already use for the Screen-Recording probe so a hung
        // tccd at most stalls one tick — not the whole app.
        return runAxTrustedCheckWithTimeout()
    }

    private static func runAxTrustedCheckWithTimeout() -> PermissionStatus {
        let semaphore = DispatchSemaphore(value: 0)
        var trusted = false
        var completed = false
        BackgroundWork.permissionsSystemCallsQueue.addOperation {
            trusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary)
            completed = true
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + 3)
        if waitResult == .timedOut || !completed {
            Logger.error { "AXIsProcessTrustedWithOptions timed out; falling back to lastKnown=\(lastKnownStatus)" }
            return lastKnownStatus
        }
        let next: PermissionStatus = trusted ? .granted : .notGranted
        lastKnownStatus = next
        return next
    }
}

class ScreenRecordingPermission {
    static var status = PermissionStatus.notGranted

    @discardableResult
    static func update() -> PermissionStatus {
        status = detect()
        return status
    }

    private static func detect() -> PermissionStatus {
        if #available(macOS 10.15, *) {
            // Short-circuit when the user has explicitly skipped Screen
            // Recording. The original code probed `isGrantedOnSomeDisplay()`
            // first and only consulted the skip flag for the negative-result
            // branch. That meant the expensive `SCShareableContent.getExcludingDesktopWindows`
            // call still ran every 5 s on the permissions timer — and each
            // call, when permission isn't clearly granted, queues a tccd
            // prompt via UserNotificationCenter. With a 6 s call-timeout
            // and a 5 s polling cadence, that produced ~12 prompts/min,
            // stacking into 50–90 visible auth popups within minutes.
            // Honor the skip flag up front so we never trigger that path.
            if Preferences.screenRecordingPermissionSkipped {
                return .skipped
            }
            return isGrantedOnSomeDisplay() ? .granted : .notGranted
        }
        return .granted
    }

    // workaround: public API CGPreflightScreenCaptureAccess and private API SLSRequestScreenCaptureAccess exist, but
    // their return value is not updated during the app lifetime
    // note: shows the system prompt if there's no permission
    private static func isGrantedOnSomeDisplay() -> Bool {
        if #available(macOS 12.3, *) {
            return checkWithSCShareableContent()
        } else {
            let mainDisplayID = CGMainDisplayID()
            if checkWithCGDisplayStream(mainDisplayID) {
                return true
            }
            // maybe the main screen can't produce a CGDisplayStream, but another screen can
            // a positive on any screen must mean that the permission is granted; we try on the other screens
            for screen in NSScreen.screens {
                if let id = screen.number(), id != mainDisplayID {
                    if checkWithCGDisplayStream(id) {
                        return true
                    }
                }
            }
            return false
        }
    }

    @available(macOS 12.3, *)
    private static func checkWithSCShareableContent() -> Bool {
        return runWithTimeout { completion in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { shareableContent, error in
                // this callback runs on a GCD queue, not on the thread that called getWithCompletionHandler
                if #available(macOS 14.0, *), let shareableContent, error == nil {
                    BackgroundWork.screenshotsQueue.addOperation {
                        WindowCaptureScreenshots.cachedSCWindows = shareableContent.windows
                    }
                }
                completion(error != nil ? false : (shareableContent != nil))
            }
        }
    }

    private static func checkWithCGDisplayStream(_ id: CGDirectDisplayID) -> Bool {
        return runWithTimeout { completion in
            // this initializer can actually block for a while
            // it's undocumented but has been proven by spindumps shared by AltTab users
            let displayStream = CGDisplayStream(
                dispatchQueueDisplay: id,
                outputWidth: 1,
                outputHeight: 1,
                pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                properties: nil,
                queue: .global()
            ) { _, _, _, _ in }
            completion(displayStream != nil)
        }
    }

    private static func runWithTimeout(_ block: @escaping (@escaping (Bool) -> Void) -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        BackgroundWork.permissionsSystemCallsQueue.addOperation {
            block { r in
                result = r
                semaphore.signal()
            }
        }
        let timeoutResult = semaphore.wait(timeout: .now() + 6)
        if timeoutResult == .timedOut {
            Logger.error { "Screen-recording permission call timed out after 6s" }
            return false
        }
        return result
    }
}
