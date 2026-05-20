import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let commandKey = CGKeyCode(55)
let graveKey = CGKeyCode(50)
let holdMs = UInt32(CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 900)

func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(20_000)
}

func releaseKnownModifiersAndKeys() {
    [CGKeyCode(55), CGKeyCode(56), CGKeyCode(58), CGKeyCode(59), CGKeyCode(48), CGKeyCode(50)].forEach { post($0, false) }
}

releaseKnownModifiersAndKeys()
post(commandKey, true, .maskCommand)
usleep(40_000)
post(graveKey, true, .maskCommand)
usleep(40_000)
post(graveKey, false, .maskCommand)
usleep(holdMs * 1000)
post(commandKey, false)
releaseKnownModifiersAndKeys()
