import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let name = CommandLine.arguments.dropFirst().first ?? "AltTabEvalA"
    let color = CommandLine.arguments.dropFirst().dropFirst().first ?? "blue"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let rect = CGRect(x: color == "red" ? 820 : 180, y: color == "red" ? 260 : 180, width: 520, height: 360)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = name
        window.contentView = EvalView(frame: CGRect(origin: .zero, size: rect.size), name: name, color: color)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class EvalView: NSView {
    let name: String
    let color: NSColor
    let logPath = ProcessInfo.processInfo.environment["ALTTAB_EVAL_KEY_LOG"] ?? "/tmp/alttab-eval-keys.log"

    init(frame: CGRect, name: String, color: String) {
        self.name = name
        self.color = color == "red" ? .systemRed : .systemBlue
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        let text = "\(name)\n\(Date())"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white]
        text.draw(in: bounds.insetBy(dx: 30, dy: 120), withAttributes: attrs)
    }

    override func flagsChanged(with event: NSEvent) {
        log("flagsChanged flags=\(event.modifierFlags.rawValue)")
    }

    override func keyDown(with event: NSEvent) {
        log("keyDown keyCode=\(event.keyCode)")
    }

    private func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(name) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
