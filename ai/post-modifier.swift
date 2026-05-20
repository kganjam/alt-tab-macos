import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let key = CGKeyCode(UInt16(CommandLine.arguments.dropFirst().first ?? "56") ?? 56)
let flag: CGEventFlags = key == 55 ? .maskCommand : key == 58 ? .maskAlternate : key == 59 ? .maskControl : .maskShift

func post(_ down: Bool, _ flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(25_000)
}

post(true, flag)
post(false)
