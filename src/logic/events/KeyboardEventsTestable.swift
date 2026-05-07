import ShortcutRecorder

class KeyboardEventsTestable {
    static var globalShortcutsIds: [String: Int] {
        var ids = [String: Int]()
        (0..<Preferences.maxShortcutCount).forEach { ids[Preferences.indexToName("nextWindowShortcut", $0)] = $0 }
        (0..<Preferences.maxShortcutCount).forEach { ids[Preferences.indexToName("holdShortcut", $0)] = Preferences.maxShortcutCount + $0 }
        return ids
    }
}

@discardableResult
func handleKeyboardEvent(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool, _ event: NSEvent? = nil) -> Bool {
    if let event, shouldAbsorbSearchEditingKeyDown(event) {
        switch TilesView.handleSearchEditingKeyDown(event) {
        case .handled: return true
        case .passToField: return false
        case .passToShortcuts: break
        }
    }
    logKeyboardEvent(globalId, shortcutState, keyCode, modifiers, isARepeat)
    let someShortcutTriggered = triggerMatchingShortcuts(globalId, shortcutState, keyCode, modifiers, isARepeat)
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
