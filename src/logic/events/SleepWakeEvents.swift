import Cocoa

class SleepWakeEvents {
    static func observe() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private static func handleWake(_ notification: Notification) {
        Logger.info { "" }
        Windows.requestZOrderReview(reason: "wake", fullDelayMs: 1000)
        reEnableAllTaps()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reEnableAllTaps() }
    }

    private static func reEnableAllTaps() {
        TrackpadEvents.reEnableTapIfNeeded()
        ScrollwheelEvents.reEnableTapIfNeeded()
        KeyboardEvents.reEnableTapIfNeeded()
        CursorEvents.reEnableTapIfNeeded()
    }
}
