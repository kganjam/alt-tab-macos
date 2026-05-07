import Cocoa
import Carbon.HIToolbox.Events

class CursorEvents {
    private static var eventTap: CFMachPort!
    private static var shouldBeEnabled: Bool!
    private static var mouseDownTarget: AnyObject?
    private static var mouseDownInsideSearchField = false
    static var deadZoneInitialPosition: CGPoint?
    static var isAllowedToMouseHover = true

    static func observe() {
        observe_()
    }

    static func toggle(_ enabled: Bool) {
        guard enabled != shouldBeEnabled else { return }
        shouldBeEnabled = enabled
        Diagnostics.log("CTAP", "toggle enabled=\(enabled)")
        if !enabled {
            deadZoneInitialPosition = nil
        }
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
        let eventMask = [CGEventType.leftMouseDown, CGEventType.leftMouseUp, CGEventType.rightMouseDown, CGEventType.rightMouseUp, CGEventType.otherMouseDown, CGEventType.otherMouseUp, CGEventType.mouseMoved].reduce(CGEventMask(0), { $0 | (1 << $1.rawValue) })
        // CGEvent.tapCreate returns nil if ensureAccessibilityCheckboxIsChecked() didn't pass
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: handleEvent,
            userInfo: nil)
        if let eventTap {
            toggle(false)
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            // we run on main-thread directly since all we do is check NSEvent and UI coordinates, which we must do on main-thread
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        } else {
            App.restart()
        }
    }

    private static let handleEvent: CGEventTapCallBack = { _, type, cgEvent, _ in
        switch type {
            case .leftMouseDown: return handleLeftMouseDown(cgEvent)
            case .leftMouseUp: return handleLeftMouseUp(cgEvent)
            case .rightMouseDown: return handleRightMouseDown(cgEvent)
            case .rightMouseUp: return handleRightMouseUp(cgEvent)
            case .otherMouseDown: return handleOtherMouseDown(cgEvent)
            case .otherMouseUp: return handleOtherMouseUp(cgEvent)
            case .mouseMoved: return handleMouseMoved(cgEvent)
            case .tapDisabledByUserInput, .tapDisabledByTimeout:
                if shouldBeEnabled { CGEvent.tapEnable(tap: eventTap!, enable: true) }
                return Unmanaged.passUnretained(cgEvent)
            default: return Unmanaged.passUnretained(cgEvent)
        }
    }

    /// Logs the click-tap decision so absorbed events become visible.
    /// The existing global NSEvent monitor in App.swift only sees clicks
    /// that were NOT absorbed by this tap — so without this, an absorbed
    /// click is invisible everywhere.
    private static func logTapDecision(_ btn: String, _ action: String, _ cgEvent: CGEvent, absorbed: Bool, reason: String = "") {
        let p = cgEvent.location
        let suffix = reason.isEmpty ? "" : " (\(reason))"
        Diagnostics.log("CTAP", "\(btn) \(action) at (\(Int(p.x)),\(Int(p.y))) absorbed=\(absorbed)\(suffix)")
    }

    private static func handleLeftMouseDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if TilesView.hasMarkedText() || ContextMenuEvents.isMenuOpen {
            logTapDecision("left", "down", cgEvent, absorbed: false, reason: "markedText/menuOpen")
            return Unmanaged.passUnretained(cgEvent)
        }
        if isPointerInsideSearchField() {
            mouseDownInsideSearchField = true
            logTapDecision("left", "down", cgEvent, absorbed: false, reason: "searchField")
            return Unmanaged.passUnretained(cgEvent)
        }
        mouseDownInsideSearchField = false
        guard isPointerInsideUi() else {
            logTapDecision("left", "down", cgEvent, absorbed: true, reason: "outsideUi")
            return nil
        }
        mouseDownTarget = (findButtonUnderPointer() ?? findTileViewUnderPointer()) as AnyObject?
        logTapDecision("left", "down", cgEvent, absorbed: true, reason: "insideUi")
        return nil
    }

    private static func handleLeftMouseUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if TilesView.hasMarkedText() || ContextMenuEvents.isMenuOpen {
            logTapDecision("left", "up", cgEvent, absorbed: false, reason: "markedText/menuOpen")
            return Unmanaged.passUnretained(cgEvent)
        }
        if mouseDownInsideSearchField || isPointerInsideSearchField() {
            mouseDownInsideSearchField = false
            logTapDecision("left", "up", cgEvent, absorbed: false, reason: "searchField")
            return Unmanaged.passUnretained(cgEvent)
        }
        guard isPointerInsideUi() else {
            if mouseDownTarget == nil { App.hideUi() }
            mouseDownTarget = nil
            logTapDecision("left", "up", cgEvent, absorbed: true, reason: "outsideUi→hideUi")
            return nil
        }
        let downTarget = mouseDownTarget
        mouseDownTarget = nil
        if let button = findButtonUnderPointer(), button === downTarget {
            button.onClick()
            logTapDecision("left", "up", cgEvent, absorbed: true, reason: "button")
            return nil
        }
        if let target = findTileViewUnderPointer(), target === downTarget {
            target.mouseUpCallback()
            logTapDecision("left", "up", cgEvent, absorbed: true, reason: "tile")
            return nil
        }
        logTapDecision("left", "up", cgEvent, absorbed: true, reason: "insideUi-noTarget")
        return nil
    }

    private static func handleRightMouseDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if ContextMenuEvents.isMenuOpen || isPointerInsideUi() {
            logTapDecision("right", "down", cgEvent, absorbed: false, reason: "menuOpen/insideUi")
            return Unmanaged.passUnretained(cgEvent)
        }
        logTapDecision("right", "down", cgEvent, absorbed: true, reason: "outsideUi")
        return nil
    }

    private static func handleRightMouseUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if ContextMenuEvents.isMenuOpen || isPointerInsideUi() {
            logTapDecision("right", "up", cgEvent, absorbed: false, reason: "menuOpen/insideUi")
            return Unmanaged.passUnretained(cgEvent)
        }
        logTapDecision("right", "up", cgEvent, absorbed: true, reason: "outsideUi")
        return nil
    }

    private static func handleOtherMouseDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if ContextMenuEvents.isMenuOpen || isPointerInsideUi() {
            logTapDecision("other", "down", cgEvent, absorbed: false, reason: "menuOpen/insideUi")
            return Unmanaged.passUnretained(cgEvent)
        }
        logTapDecision("other", "down", cgEvent, absorbed: true, reason: "outsideUi")
        return nil
    }

    private static func handleOtherMouseUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if ContextMenuEvents.isMenuOpen {
            logTapDecision("other", "up", cgEvent, absorbed: false, reason: "menuOpen")
            return Unmanaged.passUnretained(cgEvent)
        }
        if isPointerInsideUi(),
           cgEvent.getIntegerValueField(.mouseEventButtonNumber) == 2,
           let target = findTileViewUnderPointer(),
           let window = target.window_ {
            window.isWindowlessApp ? window.application.quit() : window.close()
        }
        logTapDecision("other", "up", cgEvent, absorbed: true, reason: "")
        return nil
    }

    private static func handleMouseMoved(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if isAllowedToReactToPointerMovement(cgEvent.location) {
            TilesView.thumbnailOverView.updateHover()
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    static func resetDeadzone() {
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
    }

    static func isAllowedToReactToPointerMovement(_ location: CGPoint) -> Bool {
        updateDeadzoneSituation(location)
        return isAllowedToMouseHover
    }

    private static func pointerLocationInWindow() -> NSPoint {
        TilesPanel.shared.mouseLocationOutsideOfEventStream
    }

    private static func isPointerInsideUi() -> Bool {
        TilesPanel.shared.contentLayoutRect.contains(pointerLocationInWindow())
    }

    private static func isPointerInsideSearchField() -> Bool {
        let searchField = TilesView.searchField
        if searchField.isHidden { return false }
        let point = searchField.convert(pointerLocationInWindow(), from: nil)
        return searchField.bounds.contains(point)
    }

    private static func pointerInOverlay() -> (TileOverView, NSPoint) {
        let overlay = TilesView.thumbnailOverView
        return (overlay, overlay.convert(pointerLocationInWindow(), from: nil))
    }

    private static func findButtonUnderPointer() -> TrafficLightButton? {
        let (overlay, point) = pointerInOverlay()
        return overlay.findButton(point)
    }

    private static func findTileViewUnderPointer() -> TileView? {
        let (overlay, point) = pointerInOverlay()
        return overlay.findTarget(point)
    }

    /// when using the trackpad, the user may swipe with a slight mistake. This will create a small cursor movement
    /// we ignore those, as they are not intended. Intended movements will be larger and not ignored
    private static func updateDeadzoneSituation(_ location: CGPoint) {
        guard let deadZoneInitialPosition else {
            deadZoneInitialPosition = location
            isAllowedToMouseHover = false
            return
        }
        let deltaX = location.x - deadZoneInitialPosition.x
        let deltaY = location.y - deadZoneInitialPosition.y
        if hypot(deltaX, deltaY) > 25 { isAllowedToMouseHover = true }
    }
}
