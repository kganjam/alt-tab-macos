import Cocoa
import IOKit.ps

class SleepWakeEvents {
    private static var powerSourceRunLoopSource: CFRunLoopSource?

    static func observe() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        observePowerSourceChanges()
    }

    @objc private static func handleWake(_ notification: Notification) {
        onPowerDisplayTransition("wake")
        Windows.requestZOrderReview(reason: "wake", fullDelayMs: 1000)
        reEnableAllTaps()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reEnableAllTaps() }
    }

    @objc private static func handleSleep(_ notification: Notification) {
        onPowerDisplayTransition("sleep")
    }

    /// AC <-> battery transitions make the GPU switch and WindowServer recomposite
    /// every window — and they often coincide with plugging into an external
    /// display. On this machine that's the observed trigger for the
    /// unresponsive-WindowServer freeze (2026-06-15: WindowServer spun at 30GB
    /// until the watchdog killed it). Register for power-source changes so we can
    /// log them and pause captures during the recomposite.
    private static func observePowerSourceChanges() {
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async {
                SleepWakeEvents.onPowerDisplayTransition("power-source=\(SleepWakeEvents.currentPowerSourceType())")
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private static func currentPowerSourceType() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return "unknown" }
        return (IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue()) as String? ?? "unknown"
    }

    /// Log a power/display transition and pause ALL thumbnail captures for
    /// `bgThumbnailTransitionPauseMs` so AltTab doesn't pile CGSHWCaptureWindowList
    /// work onto a WindowServer that's busy recompositing every window. Shared by
    /// wake/sleep, power-source change, and (via ScreensEvents) display reconfig.
    static func onPowerDisplayTransition(_ kind: String) {
        let pauseMs = RuntimeFlags.bgThumbnailTransitionPauseMs
        Diagnostics.log("POWER", "transition: \(kind) — pausing thumbnail captures \(pauseMs)ms (WindowServer recompositing)")
        Logger.info { "power/display transition: \(kind)" }
        App.blockThumbnailCaptures(reason: "transition:\(kind)", timeoutMs: pauseMs)
    }

    private static func reEnableAllTaps() {
        TrackpadEvents.reEnableTapIfNeeded()
        ScrollwheelEvents.reEnableTapIfNeeded()
        KeyboardEvents.reEnableTapIfNeeded()
        CursorEvents.reEnableTapIfNeeded()
    }
}
