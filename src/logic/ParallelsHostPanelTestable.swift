import Foundation

/// Pure rule that tells a Parallels helper's own AppKit window apart from the Coherence proxy of
/// a real Windows window. The case that matters is the launcher's "<App> — Starting…" panel
/// (REL-114): a 288×208 AXDialog with no title, a busy indicator and a hidden "OK" button,
/// which stays up forever when the Mac stub is launched while its Windows app already runs.
/// Every guest proxy Parallels creates carries `kCGWindowSharingReadWrite`; the helper's own
/// AppKit windows keep AppKit's default `.readOnly`. The proxies also always carry the guest
/// title, so an untitled window (AltTab then falls back to the app name) is checked against the
/// sharing state; a guest window titled like its app (Windows "Settings") keeps `.readWrite`.
class ParallelsHostPanelTestable {
    static let guestProxySharingState = 2

    static func isHostPanel(isCoherenceApp: Bool, title: String?, appName: String?, sharingState: Int?) -> Bool {
        guard isCoherenceApp, hasNoOwnTitle(title, appName), let sharingState else { return false }
        return sharingState != guestProxySharingState
    }

    static func hasNoOwnTitle(_ title: String?, _ appName: String?) -> Bool {
        guard let title, !title.isEmpty else { return true }
        return title == appName
    }
}
