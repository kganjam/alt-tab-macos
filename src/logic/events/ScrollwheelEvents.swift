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
            // When the AltTab panel is open and the cursor is NOT over the panel, eat the
            // event: otherwise it routes to whatever app is under the cursor, and some apps
            // raise themselves on scroll, which AltTab observes as external focus and
            // dismisses the panel mid-navigation. When the cursor IS over the panel, pass it
            // through so TilesView.scrollWheel scrolls the tile grid. This applies equally to
            // mouse wheel (discrete) and trackpad two-finger (continuous) scroll — previously
            // continuous scroll was blocked unconditionally, so two-finger trackpad scrolling
            // over the list never scrolled it. (3/4-finger swipe navigation is a separate
            // gesture event handled by TrackpadEvents and is unaffected.)
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
