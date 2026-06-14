class CliEvents {
    static let portName = "com.lwouis.alt-tab-macos.cli"

    static func observe() {
        var context = CFMessagePortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        if let messagePort = CFMessagePortCreateLocal(nil, portName as CFString, handleEvent, &context, nil),
           let source = CFMessagePortCreateRunLoopSource(nil, messagePort, 0) {
            CFRunLoopAddSource(BackgroundWork.cliEventsThread.runLoop, source, .commonModes)
        } else {
            Logger.error { "Can't listen on message port. Is another AltTab already running?" }
            // TODO: should we quit or restart here?
            // It's complex since AltTab can be restarted sometimes,
            // and the new instance may coexist with the old for some duration
            // There is also the case of multiple instances at login
        }
    }

    private static let handleEvent: CFMessagePortCallBack = { (_: CFMessagePort?, _: Int32, _ data: CFData?, _: UnsafeMutableRawPointer?) in
        Logger.debug { "" }
        if let data,
           let message = String(data: data as Data, encoding: .utf8) {
            Logger.info { message }
            let output = CliServer.executeCommandAndSendReponse(message)
            if let responseData = try? CliServer.jsonEncoder.encode(output) as CFData {
                return Unmanaged.passRetained(responseData)
            }
        }
        Logger.error { "Failed to decode message" }
        return nil
    }
}

class CliServer {
    static let jsonEncoder = JSONEncoder()
    static let error = "error"
    static let noOutput = "noOutput"

    // main.sync is safe here: the main thread never synchronously waits on the CLI thread
    static func executeCommandAndSendReponse(_ rawValue: String) -> Codable {
        var output: Codable = ""
        DispatchQueue.main.sync {
            output = executeCommandAndSendReponse_(rawValue)
        }
        return output
    }

    private static func executeCommandAndSendReponse_(_ rawValue: String) -> Codable {
        if rawValue == "--list" {
            return JsonWindowList(windows: Windows.list
                .filter { !$0.isWindowlessApp }
                .map { JsonWindow(id: $0.cgWindowId, title: $0.title) }
            )
        }
        if rawValue == "--detailed-list" {
            return JsonWindowFullList(windows: Windows.list
                .filter { !$0.isWindowlessApp }
                .map { jsonWindowFull($0) }
            )
        }
        if rawValue == "--selection-state" {
            return selectionState()
        }
        if rawValue == "--hide" {
            App.hideUi(true)
            return noOutput
        }
        if rawValue == "--focus-target" {
            Diagnostics.startSwitchTiming("cli-focus-target")
            App.focusTarget()
            return noOutput
        }
        if rawValue.hasPrefix("--select="),
           let id = CGWindowID(rawValue.dropFirst("--select=".count)),
           let index = Windows.list.firstIndex(where: { $0.cgWindowId == id }) {
            Windows.updateSelectedAndHoveredWindowIndex(index)
            return noOutput
        }
        if rawValue.hasPrefix("--select-and-focus="),
           let id = CGWindowID(rawValue.dropFirst("--select-and-focus=".count)),
           let index = Windows.list.firstIndex(where: { $0.cgWindowId == id }) {
            Windows.updateSelectedAndHoveredWindowIndex(index)
            let selected = Windows.selectedWindow()
            Diagnostics.startSwitchTiming("cli-select-and-focus")
            App.focusSelectedWindow(selected)
            return selectionState(selected)
        }
        if rawValue.hasPrefix("--select-index="),
           let index = Int(rawValue.dropFirst("--select-index=".count)) {
            Windows.updateSelectedAndHoveredWindowIndex(index)
            return noOutput
        }
        if rawValue.hasPrefix("--focus="),
           let id = CGWindowID(rawValue.dropFirst("--focus=".count)) {
            Diagnostics.startSwitchTiming("cli-focus")
            App.hideUi(true)
            // Focuses immediately if known; otherwise discovers the window
            // on-demand (no wait for the throttled windowCreated scan), so a
            // just-created window passed straight from CGWindowList focuses fast.
            Windows.focusWindowByIdOnDemand(id)
            return noOutput
        }
        if rawValue.hasPrefix("--focus-newest=") {
            // Focus the newest window of an app bundle, discovering it on-demand.
            // Lets a "open a new window" helper do: create window -> one CLI call,
            // with no polling — AltTab finds the just-created window itself and
            // reports the app that was frontmost (so the caller can restore it
            // when the new window closes).
            let bundleId = String(rawValue.dropFirst("--focus-newest=".count))
            guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId })?.processIdentifier,
                  let newWid = Windows.newestWindowId(forPid: pid) else {
                return error
            }
            let prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            Diagnostics.startSwitchTiming("cli-focus-newest")
            App.hideUi(true)
            Windows.focusWindowByIdOnDemand(newWid)
            return JsonScratchFocus(newWindowId: newWid, previousFrontmostBundleId: prevBundle)
        }
        if rawValue.hasPrefix("--focusUsingLastFocusOrder="),
           let lastFocusOrder = Int(rawValue.dropFirst("--focusUsingLastFocusOrder=".count)), let window = (Windows.list.first { $0.lastFocusOrder == lastFocusOrder }) {
            Diagnostics.startSwitchTiming("cli-focus-last-order")
            App.hideUi(true)
            window.focus()
            return noOutput
        }
        if rawValue.hasPrefix("--show="),
           let shortcutIndex = Int(rawValue.dropFirst("--show=".count)), (0..<Preferences.shortcutCount).contains(shortcutIndex) {
            App.showUi(shortcutIndex)
            return noOutput
        }
        return error
    }

    private static func selectionState(_ selectedWindow: Window? = Windows.selectedWindow()) -> JsonSelectionState {
        JsonSelectionState(
            appIsBeingUsed: App.appIsBeingUsed,
            selectedIndex: Windows.selectedWindowIndex,
            selectedWindow: selectedWindow.map { jsonWindowFull($0) },
            visibleThumbnailWindowIds: App.appIsBeingUsed ? TilesView.visibleWindowsForThumbnailRefresh().compactMap { $0.cgWindowId } : [],
            windows: Windows.list.filter { !$0.isWindowlessApp }.map { jsonWindowFull($0) })
    }

    private static func jsonWindowFull(_ window: Window) -> JsonWindowFull {
        let now = CFAbsoluteTimeGetCurrent()
        let thumbnailAgeMs = window.thumbnailUpdatedAt > 0 ? (now - window.thumbnailUpdatedAt) * 1000 : nil
        return JsonWindowFull(
            id: window.cgWindowId,
            pid: window.application.pid,
            title: window.title,
            appName: window.application.localizedName,
            appBundleId: window.application.bundleIdentifier,
            spaceIndexes: window.spaceIndexes,
            lastFocusOrder: window.lastFocusOrder,
            creationOrder: window.creationOrder,
            isTabbed: window.isTabbed,
            isHidden: window.isHidden,
            isFullscreen: window.isFullscreen,
            isMinimized: window.isMinimized,
            isOnAllSpaces: window.isOnAllSpaces,
            position: window.position,
            size: window.size,
            hasThumbnail: window.thumbnail != nil,
            thumbnailAgeMs: thumbnailAgeMs,
            thumbnailUpdateCount: window.thumbnailUpdateCount,
            shouldShowTheUser: window.shouldShowTheUser,
            displayHideReasons: Windows.displayHideReasons(window),
            isDisplayable: Windows.isDisplayableForCurrentUi(window)
        )
    }

    private struct JsonScratchFocus: Codable {
        var newWindowId: CGWindowID
        var previousFrontmostBundleId: String
    }

    private struct JsonWindowList: Codable {
        var windows: [JsonWindow]
    }

    private struct JsonWindow: Codable {
        var id: CGWindowID?
        var title: String
    }

    private struct JsonWindowFullList: Codable {
        var windows: [JsonWindowFull]
    }

    private struct JsonSelectionState: Codable {
        var appIsBeingUsed: Bool
        var selectedIndex: Int
        var selectedWindow: JsonWindowFull?
        var visibleThumbnailWindowIds: [CGWindowID]
        var windows: [JsonWindowFull]
    }

    private struct JsonWindowFull: Codable {
        var id: CGWindowID?
        var pid: pid_t
        var title: String
        // -- additional properties
        var appName: String?
        var appBundleId: String?
        var spaceIndexes: [SpaceIndex]
        var lastFocusOrder: Int
        var creationOrder: Int
        var isTabbed: Bool
        var isHidden: Bool
        var isFullscreen: Bool
        var isMinimized: Bool
        var isOnAllSpaces: Bool
        var position: CGPoint?
        var size: CGSize?
        var hasThumbnail: Bool
        var thumbnailAgeMs: Double?
        var thumbnailUpdateCount: Int
        var shouldShowTheUser: Bool
        var displayHideReasons: [String]
        var isDisplayable: Bool
    }
}

class CliClient {
    static func detectCommand() -> String? {
        let args = CommandLine.arguments
        if args.count == 2 && !args[1].starts(with: "--logs=") {
            if args[1] == "--list" || args[1] == "--detailed-list" || args[1] == "--selection-state" || args[1] == "--hide" || args[1] == "--focus-target" || args[1].hasPrefix("--select=") || args[1].hasPrefix("--select-index=") || args[1].hasPrefix("--select-and-focus=") || args[1].hasPrefix("--focus=") || args[1].hasPrefix("--focus-newest=") || args[1].hasPrefix("--focusUsingLastFocusOrder=") || args[1].hasPrefix("--show=") {
                return args[1]
            }
        }
        return nil
    }

    static func sendCommandAndProcessResponse(_ command: String) {
        do {
            let serverPortClient = try CFMessagePortCreateRemote(nil, CliEvents.portName as CFString).unwrapOrThrow()
            let data = try command.data(using: .utf8).unwrapOrThrow()
            var returnData: Unmanaged<CFData>?
            let _ = CFMessagePortSendRequest(serverPortClient, 0, data as CFData, 2, 2, CFRunLoopMode.defaultMode.rawValue, &returnData)
            let responseData = try returnData.unwrapOrThrow().takeRetainedValue()
            if let response = String(data: responseData as Data, encoding: .utf8) {
                if response != "\"\(CliServer.error)\"" {
                    if response != "\"\(CliServer.noOutput)\"" {
                        print(response)
                    }
                    exit(0)
                }
            }
            print("Couldn't execute command. Is it correct?")
            exit(1)
        } catch {
            print("AltTab.app needs to be running for CLI commands to work")
            exit(1)
        }
    }
}
