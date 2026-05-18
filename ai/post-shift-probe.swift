import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let shiftKey: CGKeyCode = 56

func post(_ down: Bool) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: down) else { return }
    event.flags = down ? .maskShift : []
    event.post(tap: .cghidEventTap)
    usleep(30_000)
}

post(true)
post(false)
