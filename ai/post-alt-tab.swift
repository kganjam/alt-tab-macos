import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let modifierName = CommandLine.arguments.dropFirst().first ?? "option"
let tabKey: CGKeyCode = 48
let downMs = UInt32(CommandLine.arguments.dropFirst().dropFirst().first.flatMap(Int.init) ?? 45)
let modifier: (key: CGKeyCode, flag: CGEventFlags) = {
    switch modifierName {
    case "command", "cmd": return (55, .maskCommand)
    case "control", "ctrl": return (59, .maskControl)
    case "shift": return (56, .maskShift)
    default: return (58, .maskAlternate)
    }
}()

func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(20_000)
}

func releaseKnownModifiers() {
    [CGKeyCode(55), CGKeyCode(56), CGKeyCode(58), CGKeyCode(59), CGKeyCode(48)].forEach { post($0, false) }
}

releaseKnownModifiers()
post(modifier.key, true, modifier.flag)
usleep(downMs * 1000)
post(tabKey, true, modifier.flag)
usleep(downMs * 1000)
post(tabKey, false, modifier.flag)
usleep(downMs * 1000)
post(modifier.key, false)
releaseKnownModifiers()
