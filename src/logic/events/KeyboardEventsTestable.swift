import Carbon.HIToolbox.Events
import ShortcutRecorder

class KeyboardEventsTestable {
    private static var lastObservedModifiers: NSEvent.ModifierFlags?
    private static var lastObservedModifiersAt = CFAbsoluteTimeGetCurrent()

    static var globalShortcutsIds: [String: Int] {
        var ids = [String: Int]()
        (0..<Preferences.maxShortcutCount).forEach { ids[Preferences.indexToName("nextWindowShortcut", $0)] = $0 }
        (0..<Preferences.maxShortcutCount).forEach { ids[Preferences.indexToName("holdShortcut", $0)] = Preferences.maxShortcutCount + $0 }
        return ids
    }

    static func noteModifiers(_ modifiers: NSEvent.ModifierFlags?) {
        guard let modifiers else { return }
        lastObservedModifiers = modifiers
        lastObservedModifiersAt = CFAbsoluteTimeGetCurrent()
    }

    static func resetForTests() {
        lastObservedModifiers = nil
        lastObservedModifiersAt = 0
    }

    static func activeHoldModifierIsDown(_ modifiers: NSEvent.ModifierFlags? = nil) -> Bool {
        guard App.appIsBeingUsed,
              let holdShortcut = ControlsTab.shortcuts[Preferences.indexToName("holdShortcut", App.shortcutIndex)]?.shortcut else { return false }
        let current = modifiers ?? ModifierFlags.current
        let currentModifiers = cocoaToCarbonFlags(current).cleaned()
        let holdModifiers = holdShortcut.carbonModifierFlags.cleaned()
        return holdModifiers != 0 && currentModifiers & holdModifiers == holdModifiers
    }

    static func modifierOnlyEventCanReleaseZOrder(_ modifiers: NSEvent.ModifierFlags?) -> Bool {
        guard let modifiers else { return false }
        let currentModifiers = cocoaToCarbonFlags(modifiers).cleaned()
        guard currentModifiers != 0 else { return false }
        for shortcutModifiers in configuredShortcutModifierSets() where currentModifiers & shortcutModifiers == currentModifiers {
            return false
        }
        return true
    }

    static func isNativeCommandNumberShortcut(_ controlId: String, _ shortcut: Shortcut) -> Bool {
        guard controlId.hasPrefix("nextWindowShortcut") else { return false }
        let modifiers = shortcut.carbonModifierFlags.cleaned()
        let commandOnly = modifiers == UInt32(cmdKey)
        return commandOnly && nativeCommandNumberKeyCodes.contains(shortcut.carbonKeyCode)
    }

    private static let nativeCommandNumberKeyCodes = Set([
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
    ])

    private static func recentObservedModifiers() -> NSEvent.ModifierFlags? {
        guard CFAbsoluteTimeGetCurrent() - lastObservedModifiersAt < 1.0 else { return nil }
        return lastObservedModifiers
    }

    private static func configuredShortcutModifierSets() -> [CarbonModifierFlags] {
        (0..<Preferences.maxShortcutCount).flatMap { index in
            [
                shortcutModifiers(Preferences.indexToName("nextWindowShortcut", index)),
                shortcutModifiers(Preferences.indexToName("holdShortcut", index)),
            ].compactMap { $0 }
        }
    }

    private static func shortcutModifiers(_ name: String) -> CarbonModifierFlags? {
        ControlsTab.shortcuts[name]?.shortcut.carbonModifierFlags.cleaned()
    }
}

@discardableResult
func handleKeyboardEvent(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool, _ event: NSEvent? = nil) -> Bool {
    if let event, shouldAbsorbSearchEditingKeyDown(event) {
        App.noteInputCaptureActivity("search-key")
        switch TilesView.handleSearchEditingKeyDown(event) {
        case .handled: return true
        case .passToField: return false
        case .passToShortcuts: break
        }
    }
    KeyboardEventsTestable.noteModifiers(modifiers)
    logKeyboardEvent(globalId, shortcutState, keyCode, modifiers, isARepeat)
    if let globalId, let shortcutState {
        let shortcut = KeyboardEventsTestable.globalShortcutsIds.first { $0.value == globalId }
        Windows.noteAltTabShortcutInput(label: "\(shortcut?.key ?? "?")-\(shortcutState)")
    }
    let someShortcutTriggered = triggerMatchingShortcuts(globalId, shortcutState, keyCode, modifiers, isARepeat)
    let holdModifierStillDown = KeyboardEventsTestable.activeHoldModifierIsDown(modifiers)
    if holdModifierStillDown {
        App.noteInputCaptureActivity("hold-modifier")
    }
    if someShortcutTriggered && App.appIsBeingUsed {
        App.noteInputCaptureActivity("keyboard-shortcut")
    }
    if !someShortcutTriggered && !App.appIsBeingUsed {
        let label = keyCode.map { "key=\($0)" } ?? modifiers.map { "modifiers=\($0.rawValue)" } ?? "unknown"
        let canReleaseZOrder = keyCode != nil || KeyboardEventsTestable.modifierOnlyEventCanReleaseZOrder(modifiers)
        Windows.releaseZOrderEnforcementForExternalKeyboardInput(label: label, canReleaseZOrder: canReleaseZOrder)
    }
    if !someShortcutTriggered && App.appIsBeingUsed && !holdModifierStillDown && App.inputCaptureIsOlderThan(RuntimeFlags.inputCapturePassthroughMs) {
        if App.deferStaleInputCaptureHideIfFocusIsSettling() { return someShortcutTriggered }
        Diagnostics.log("CAPTURE", "keyboard hiding stale input capture after \(RuntimeFlags.inputCapturePassthroughMs)ms")
        App.hideUi()
    }
    return someShortcutTriggered
}

private func logKeyboardEvent(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool) {
    if let globalId, let shortcutState {
        let shortcut = KeyboardEventsTestable.globalShortcutsIds.first { $0.value == globalId }
        Diagnostics.log("KEYEVENT", "hotkey \(shortcut?.key ?? "?") \(shortcutState) (globalId=\(globalId))")
        // t0 for end-to-end switch latency. Reset on every hotkey event
        // (press or release) so the most recent press/release is the
        // time origin for the focus that follows.
        Diagnostics.startSwitchTiming("\(shortcut?.key ?? "hotkey")-\(shortcutState)")
        Logger.debug { "globalShortcut:\(shortcut?.key ?? "") state:\(shortcutState)" }
        return
    }
    if let keyCode {
        let dir = (modifiers != nil) ? "flags" : "key"
        Diagnostics.log("KEYEVENT", "\(dir) code=\(keyCode) isRepeat=\(isARepeat)")
    } else if let modifiers {
        Diagnostics.log("KEYEVENT", "modifiers=\(modifiers.rawValue)")
    }
    Logger.debug {
        let modifiersAsString = modifiers.flatMap { SymbolicModifierFlagsTransformer.shared.transformedValue(NSNumber(value: $0.rawValue)) }
        let keyCodeAsString = keyCode.flatMap { SymbolicKeyCodeTransformer.shared.transformedValue(NSNumber(value: $0)) }
        return "keys:\(modifiersAsString ?? "")\(keyCodeAsString ?? "") isARepeat:\(isARepeat)"
    }
}

private func shouldAbsorbSearchEditingKeyDown(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .keyDown, App.appIsBeingUsed, TilesPanel.shared.isKeyWindow, TilesView.isSearchEditing else {
        return false
    }
    return true
}

private func triggerMatchingShortcuts(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool) -> Bool {
    var someShortcutTriggered = false
    for shortcut in ControlsTab.shortcuts.values {
        if shortcut.matches(globalId, shortcutState, keyCode, modifiers) && shortcut.shouldTrigger() {
            shortcut.executeAction(isARepeat)
            // we want to pass-through alt-up to the active app, since it saw alt-down previously
            if !shortcut.id.starts(with: "holdShortcut") {
                someShortcutTriggered = true
            }
        }
        shortcut.redundantSafetyMeasures()
    }
    // TODO if we manage to move all keyboard listening to the background thread, we'll have issues returning this boolean
    // this function uses many objects that are also used on the main-thread. It also executes the actions
    // we'll have to rework this whole approach. Today we rely on somewhat in-order events/actions
    // special attention should be given to App.appIsBeingUsed which is being set to true when executing the nextWindowShortcut action
    return someShortcutTriggered
}
