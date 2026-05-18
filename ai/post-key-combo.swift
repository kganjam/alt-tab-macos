import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let commandKey: CGKeyCode = 55
let commandFlag = CGEventFlags.maskCommand

func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(25_000)
}

func releaseKnownModifiers() {
    [CGKeyCode(55), CGKeyCode(56), CGKeyCode(58), CGKeyCode(59), CGKeyCode(48)].forEach { post($0, false) }
}

releaseKnownModifiers()
for arg in CommandLine.arguments.dropFirst() {
    guard let raw = UInt16(arg) else { continue }
    let key = CGKeyCode(raw)
    post(commandKey, true, commandFlag)
    post(key, true, commandFlag)
    post(key, false, commandFlag)
    post(commandKey, false)
    usleep(75_000)
}
releaseKnownModifiers()
