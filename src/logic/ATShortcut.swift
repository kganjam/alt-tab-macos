import Cocoa
import ShortcutRecorder

class ATShortcut {
    static var lastEventIsARepeat = false
    private static var didTriggerHoldShortcutRelease = false
    var shortcut: Shortcut
    var id: String
    var scope: ShortcutScope
    var triggerPhase: ShortcutTriggerPhase
    var state: ShortcutState = .up
    var index: Int?
    /// A hold shortcut whose key is fn (`holdKeyIsFn`). A Shortcut cannot carry fn, so `shortcut` is
    /// then empty and fn is checked on the event's Cocoa flags.
    let requiresFn: Bool

    init(_ shortcut: Shortcut, _ id: String, _ scope: ShortcutScope, _ triggerPhase: ShortcutTriggerPhase, _ index: Int? = nil, requiresFn: Bool = false) {
        self.shortcut = shortcut
        self.id = id
        self.scope = scope
        self.triggerPhase = triggerPhase
        self.index = index
        self.requiresFn = requiresFn
    }

    /// For a hold shortcut: its modifiers (at least) are down in `modifiers`, fn included when it needs fn.
    func holdModifiersAreDown(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        let holdModifiers = shortcut.carbonModifierFlags.cleaned()
        guard holdModifiers != 0 || requiresFn else { return false }
        let fnMatches = !requiresFn || modifiers.contains(.function)
        return fnMatches && cocoaToCarbonFlags(modifiers).cleaned() & holdModifiers == holdModifiers
    }

    func matches(_ id: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?) -> Bool {
        if let id, let shortcutState, let shortcutId = KeyboardEventsTestable.globalShortcutsIds.first(where: { $0.value == id })?.key {
            if shortcutId == self.id {
                state = shortcutState
                if (triggerPhase == .down && state == .down) || (triggerPhase == .up && state == .up) {
                    return true
                }
            }
        }
        if let modifiers {
            let modifiersMatch_ = modifiersMatch(modifiers)
            let newState: ShortcutState = ((shortcut.keyCode == .none || keyCode == shortcut.carbonKeyCode) && modifiersMatch_) ? .down : .up
            let flipped = state != newState
            state = newState
            // state == down is unambiguous; state == up is hard to match with a particular shortcut, unless it's been flipped
            if (triggerPhase == .down && state == .down) || (triggerPhase == .up && state == .up && flipped) {
                return true
            }
        }
        return false
    }

    private func modifiersMatch(_ cocoaModifiers: NSEvent.ModifierFlags) -> Bool {
        let modifiersCleaned = cocoaToCarbonFlags(cocoaModifiers).cleaned()
        let shortcutModifiersCleaned = shortcut.carbonModifierFlags.cleaned()
        // holdShortcut: contains at least
        if id.hasPrefix("holdShortcut") {
            return modifiersCleaned == (modifiersCleaned | shortcutModifiersCleaned) && (!requiresFn || cocoaModifiers.contains(.function))
        }
        // other shortcuts: contains exactly or exactly + holdShortcut modifiers
        let holdModifiersCleaned = ControlsTab.shortcuts[Preferences.indexToName("holdShortcut", App.shortcutIndex)]?.shortcut.carbonModifierFlags.cleaned() ?? 0
        // nextWindowShortcut when panel is open: also match base key without holdShortcut modifiers
        if App.appIsBeingUsed && id.hasPrefix("nextWindowShortcut") {
            let baseModifiersCleaned = shortcutModifiersCleaned & ~holdModifiersCleaned
            if modifiersCleaned == baseModifiersCleaned {
                return true
            }
        }
        return modifiersCleaned == shortcutModifiersCleaned || modifiersCleaned == (shortcutModifiersCleaned | holdModifiersCleaned)
    }

    func shouldTrigger() -> Bool {
        if scope == .global {
            if triggerPhase == .down && (!App.appIsBeingUsed || index == nil || index == App.shortcutIndex) {
                return true
            }
            if triggerPhase == .up && App.appIsBeingUsed && (index == nil || index == App.shortcutIndex) && !App.forceDoNothingOnRelease && Preferences.shortcutStyle == .focusOnRelease {
                return true
            }
        }
        if scope == .local {
            if App.appIsBeingUsed && (index == nil || index == App.shortcutIndex) {
                return true
            }
        }
        return false
    }

    func executeAction(_ isARepeat: Bool) {
        Logger.info { self.id }
        ATShortcut.lastEventIsARepeat = isARepeat
        if id.hasPrefix("nextWindowShortcut") && triggerPhase == .down {
            ATShortcut.didTriggerHoldShortcutRelease = false
        } else if id.hasPrefix("holdShortcut") {
            ATShortcut.didTriggerHoldShortcutRelease = true
        }
        ControlsTab.executeAction(id)
    }

    static func resetForTests() {
        lastEventIsARepeat = false
        didTriggerHoldShortcutRelease = false
    }

    /// keyboard events can be unreliable. They can arrive in the wrong order, or may never arrive
    /// this function acts as a safety net to improve the chances that some keyUp behaviors are enforced
    func redundantSafetyMeasures() {
        // Keyboard shortcuts come from different sources. As a result, they can arrive in the wrong order (e.g. alt DOWN > alt UP > alt+tab DOWN > alt+tab UP)
        // The events can be disordered between sources, but not within each source
        // Another issue is events being dropped by macOS, which we never receive
        // Knowing this, we handle these edge-cases by double checking if holdShortcut is UP, when any shortcut state is UP
        // If it is, then we trigger the holdShortcut action
        if App.appIsBeingUsed && !App.forceDoNothingOnRelease && Preferences.shortcutStyle == .focusOnRelease {
            if let currentHoldShortcut = ControlsTab.shortcuts[Preferences.indexToName("holdShortcut", App.shortcutIndex)],
               id == currentHoldShortcut.id {
                if !KeyboardEventsTestable.activeHoldModifierIsDown() {
                    if !ATShortcut.didTriggerHoldShortcutRelease {
                        currentHoldShortcut.state = .up
                        currentHoldShortcut.executeAction(false)
                    }
                }
            }
        }
        if state == .up {
            // ensure timers don't keep running if their shortcut is UP
            KeyRepeatTimer.stopTimerForRepeatingKey(id)
        }
    }
}

enum ShortcutTriggerPhase {
    case down
    case up
}

enum ShortcutState {
    case down
    case up
}

enum ShortcutScope {
    case global
    case local
}

extension NSEvent.ModifierFlags {
    // NSEvent.addLocalMonitorForEvents may return events with broken modifiers (e.g. [.NSEventModifierFlagOption, .NSEventModifierFlagFunction, 0x120])
    // we filter modifiers to only include valid modifiers; which doesn't include fn: fn is only a hold key (ATShortcut.requiresFn), checked apart
    func cleaned() -> Self {
        return self.intersection([.command, .shift, .option, .control, .capsLock])
    }
}

typealias CarbonModifierFlags = UInt32

extension CarbonModifierFlags {
    // cocoaToCarbonFlags may remove NSEventModifierFlagFunction
    // we filter modifiers to only include valid modifiers; which doesn't include fn: fn is only a hold key (ATShortcut.requiresFn), checked apart
    func cleaned() -> Self {
        return self & (UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(alphaLock))
    }
}
