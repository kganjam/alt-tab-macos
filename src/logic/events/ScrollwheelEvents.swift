import Cocoa

class ScrollwheelEvents {
    static var shouldBeEnabled: Bool!
    private static var eventTap: CFMachPort!

    static func observe() {
        observe_()
        toggle(false)
    }

    static func toggle(_ enabled: Bool) {
        guard enabled != shouldBeEnabled else { return }
        shouldBeEnabled = enabled
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: enabled)
        }
    }

    static func reEnableTapIfNeeded() {
        guard let eventTap, shouldBeEnabled, !CGEvent.tapIsEnabled(tap: eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Logger.warning { "" }
    }

    private static func observe_() {
        // CGEvent.tapCreate returns null if ensureAccessibilityCheckboxIsChecked() didn't pass
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap, // we need raw data
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.scrollWheel.rawValue,
            callback: handleEvent,
            userInfo: nil)
        if let eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(BackgroundWork.keyboardAndMouseAndTrackpadEventsThread.runLoop, runLoopSource, .commonModes)
        } else {
            App.restart()
        }
    }

    private static let handleEvent: CGEventTapCallBack = { _, type, cgEvent, _ in
        if type.rawValue == NSEvent.EventType.scrollWheel.rawValue {
            App.noteInputCaptureActivity("scrollwheel-tap")
            let isContinuous = cgEvent.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            // Block continuous (trackpad two-finger) scrolling unconditionally —
            // trackpad gesture detector handles tile navigation instead.
            if isContinuous { return nil }
            // Discrete (mouse wheel): when the AltTab panel is open and the
            // cursor is NOT over the panel, eat the event. Without this, the
            // scroll routes to whatever app is under the cursor; some apps
            // raise themselves on scroll, AltTab observes the external focus
            // and dismisses the panel mid-navigation. When the cursor IS over
            // the panel, pass through so TilesView.scrollWheel can scroll the
            // tile grid.
            if App.appIsBeingUsed && !isPointerInsidePanel() { return nil }
            return Unmanaged.passUnretained(cgEvent)
        }
        if (type == .tapDisabledByUserInput || type == .tapDisabledByTimeout) && shouldBeEnabled {
            CGEvent.tapEnable(tap: eventTap!, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent) // focused app will receive the event
    }

    /// Whether the OS cursor sits inside the AltTab panel's content rect.
    /// Called from the HID-level CGEventTap callback (not main), so we use
    /// `mouseLocationOutsideOfEventStream` which is thread-safe.
    private static func isPointerInsidePanel() -> Bool {
        return TilesPanel.shared.contentLayoutRect.contains(TilesPanel.shared.mouseLocationOutsideOfEventStream)
    }
}
