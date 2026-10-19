import Cocoa

extension CGWindowID {
    func title() -> String? {
        cgProperty("kCGSWindowTitle", String.self)
    }

    func level() -> CGWindowLevel {
        var level = CGWindowLevel(0)
        CGSGetWindowLevel(CGS_CONNECTION, self, &level)
        return level
    }

    /// `kCGWindowSharingState` from WindowServer's description of this one window (no Screen
    /// Recording needed); nil once the window is gone.
    func sharingState() -> Int? {
        var id = UnsafeRawPointer(bitPattern: UInt(self))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &id, 1, nil),
              let window = (CGWindowListCreateDescriptionFromArray(ids) as? [CGWindow])?.first else { return nil }
        return window.sharingState()
    }

    func spaces() -> [CGSSpaceID] {
        return CGSCopySpacesForWindows(CGS_CONNECTION, CGSSpaceMask.all.rawValue, [self] as CFArray) as! [CGSSpaceID]
    }

    private func cgProperty<T>(_ key: String, _ type: T.Type) -> T? {
        var value: AnyObject?
        CGSCopyWindowProperty(CGS_CONNECTION, self, key as CFString, &value)
        return value as? T
    }
}
