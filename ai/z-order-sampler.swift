import Cocoa
import Carbon
import CoreGraphics
import Foundation

@_silgen_name("GetFrontProcess")
func CarbonGetFrontProcess(_ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("GetProcessPID")
func CarbonGetProcessPID(_ psn: UnsafePointer<ProcessSerialNumber>, _ pid: UnsafeMutablePointer<pid_t>) -> OSStatus

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

struct Args {
    var targetWid: UInt32 = 0
    var targetPid: Int32 = 0
    var targetOwner = ""
    var durationMs = 2500
    var intervalMs = 5
    var sampleAx = true
}

struct Row {
    let wid: UInt32
    let pid: Int32
    let owner: String
}

let blocklistedOwners: Set<String> = [
    "Window Server", "Control Center", "Dock", "AltTab", "Notification Center",
    "SystemUIServer", "Spotlight", "Menubar", "Wallpaper", "CursorUIViewService",
    "UserNotificationCenter",
    "LocalAuthenticationRemoteService",
]

func parseArgs() -> Args {
    var args = Args()
    var i = 1
    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
        switch arg {
        case "--target-wid": args.targetWid = UInt32(next) ?? 0; i += 1
        case "--target-pid": args.targetPid = Int32(next) ?? 0; i += 1
        case "--target-owner": args.targetOwner = next; i += 1
        case "--duration-ms": args.durationMs = Int(next) ?? args.durationMs; i += 1
        case "--interval-ms": args.intervalMs = Int(next) ?? args.intervalMs; i += 1
        case "--no-ax": args.sampleAx = false
        default: break
        }
        i += 1
    }
    return args
}

func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

func numberOrNull(_ value: Int?) -> String {
    value.map(String.init) ?? "null"
}

func visibleRows() -> (raw: [Row], app: [Row]) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
    let raw = info.compactMap { row -> Row? in
        guard (row[kCGWindowLayer as String] as? Int) == 0,
              let wid = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let owner = row[kCGWindowOwnerName as String] as? String,
              let boundsDict = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 40,
              bounds.height >= 40,
              (row[kCGWindowAlpha as String] as? Double ?? 1.0) >= 0.05 else { return nil }
        return Row(wid: wid, pid: pid, owner: owner)
    }
    return (raw, raw.filter { !blocklistedOwners.contains($0.owner) })
}

func ownerMatches(_ row: Row, _ owner: String) -> Bool {
    !owner.isEmpty && row.owner.range(of: owner, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

func carbonFrontProcessPid() -> pid_t {
    var psn = ProcessSerialNumber()
    guard CarbonGetFrontProcess(&psn) == noErr else { return 0 }
    var pid: pid_t = 0
    guard CarbonGetProcessPID(&psn, &pid) == noErr else { return 0 }
    return pid
}

func frontProcessPid(sampleAx: Bool, axPid: pid_t?, carbonPid: pid_t?, nsPid: pid_t?) -> pid_t {
    if sampleAx, let axPid {
        return axPid
    }
    if let carbonPid, carbonPid != 0 { return carbonPid }
    return nsPid ?? 0
}

func axFocusedApplicationPid() -> pid_t? {
    let system = AXUIElementCreateSystemWide()
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
          let app = value else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(app as! AXUIElement, &pid) == .success else { return nil }
    return pid
}

func axFocusedWindowId(pid: pid_t) -> UInt32? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.05)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let window = value else { return nil }
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(window as! AXUIElement, &wid) == .success, wid != 0 else { return nil }
    return UInt32(wid)
}

func appName(pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
}

let args = parseArgs()
let started = DispatchTime.now().uptimeNanoseconds
let durationNs = UInt64(max(1, args.durationMs)) * 1_000_000
let intervalUs = useconds_t(max(1, args.intervalMs) * 1000)

while true {
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsedNs = now - started
    if elapsedNs > durationNs { break }
    let rows = visibleRows()
    let ownerTarget = rows.app.first { ownerMatches($0, args.targetOwner) }
    let targetPid = args.targetPid != 0 ? args.targetPid : (rows.app.first { $0.wid == args.targetWid }?.pid ?? ownerTarget?.pid ?? 0)
    let targetWid = args.targetWid != 0 ? args.targetWid : (rows.app.first { $0.pid == targetPid && targetPid != 0 }?.wid ?? ownerTarget?.wid ?? 0)
    let targetZ = targetWid != 0 ? rows.app.firstIndex { $0.wid == targetWid } : (targetPid != 0 ? rows.app.firstIndex { $0.pid == targetPid } : nil)
    let above = targetZ.map { Array(rows.app.prefix($0)) } ?? rows.app
    let sameAbove = targetPid == 0 ? [] : above.filter { $0.pid == targetPid && $0.wid != targetWid }
    let sameTop8 = targetPid == 0 ? 0 : rows.app.prefix(8).filter { $0.pid == targetPid }.count
    let rawTop = rows.raw.first
    let appTop = rows.app.first
    let topRows = Array(rows.app.prefix(16))
    let front = NSWorkspace.shared.frontmostApplication
    let nsPid = front?.processIdentifier
    let axPid = args.sampleAx ? axFocusedApplicationPid() : nil
    let carbonPid = carbonFrontProcessPid()
    let frontPid = frontProcessPid(sampleAx: args.sampleAx, axPid: axPid, carbonPid: carbonPid, nsPid: nsPid)
    let frontName = appName(pid: frontPid)
    let axFocusedWid = args.sampleAx ? axFocusedWindowId(pid: frontPid) : nil
    let parts = [
        "\"utc_ms\":\(Int64(Date().timeIntervalSince1970 * 1000))",
        "\"t_ms\":\(String(format: "%.3f", Double(elapsedNs) / 1_000_000.0))",
        "\"front_pid\":\(frontPid)",
        "\"ax_front_pid\":\(axPid.map { String($0) } ?? "null")",
        "\"carbon_front_pid\":\(carbonPid)",
        "\"ns_front_pid\":\(nsPid ?? 0)",
        "\"front_name\":\(jsonString(frontName.isEmpty ? (front?.localizedName ?? "") : frontName))",
        "\"ax_focused_wid\":\(axFocusedWid.map { String($0) } ?? "null")",
        "\"raw_top_wid\":\(rawTop.map { String($0.wid) } ?? "null")",
        "\"raw_top_pid\":\(rawTop.map { String($0.pid) } ?? "null")",
        "\"raw_top_owner\":\(jsonString(rawTop?.owner ?? ""))",
        "\"top_wid\":\(appTop.map { String($0.wid) } ?? "null")",
        "\"top_pid\":\(appTop.map { String($0.pid) } ?? "null")",
        "\"top_owner\":\(jsonString(appTop?.owner ?? ""))",
        "\"target_wid\":\(targetWid)",
        "\"target_pid\":\(targetPid)",
        "\"target_owner\":\(jsonString(args.targetOwner))",
        "\"target_z\":\(numberOrNull(targetZ))",
        "\"same_app_above\":\(sameAbove.count)",
        "\"same_app_top8\":\(sameTop8)",
        "\"same_app_above_wids\":[\(sameAbove.prefix(8).map { String($0.wid) }.joined(separator: ","))]",
        "\"top_wids\":[\(topRows.map { String($0.wid) }.joined(separator: ","))]",
        "\"top_pids\":[\(topRows.map { String($0.pid) }.joined(separator: ","))]",
        "\"top_owners\":[\(topRows.map { jsonString($0.owner) }.joined(separator: ","))]",
    ]
    print("{\(parts.joined(separator: ","))}")
    fflush(stdout)
    usleep(intervalUs)
}
