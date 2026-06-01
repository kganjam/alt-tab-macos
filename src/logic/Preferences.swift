import Cocoa
import Carbon.HIToolbox.Events
import ShortcutRecorder

class Preferences {
    static var defaultValues: [String: Any] = {
        var values: [String: Any] = [
            "shortcutCount": "2",
            "nextWindowGesture": GesturePreference.disabled.indexAsString,
            "focusWindowShortcut": defaultShortcut(returnKeyEquivalent()),
            "previousWindowShortcut": defaultShortcut("⇧"),
            "cancelShortcut": defaultShortcut("⎋"),
            "lockSearchShortcut": defaultShortcut("Space"),
            "closeWindowShortcut": defaultShortcut("W"),
            "minDeminWindowShortcut": defaultShortcut("M"),
            "toggleFullscreenWindowShortcut": defaultShortcut("F"),
            "quitAppShortcut": defaultShortcut("Q"),
            "hideShowAppShortcut": defaultShortcut("H"),
            "searchShortcut": defaultShortcut("S"),
            "arrowKeysEnabled": "true",
            "vimKeysEnabled": "false",
            "mouseHoverEnabled": "false",
            "scrollPanelOnEdgeHover": "false",
            "cursorFollowFocus": CursorFollowFocus.never.indexAsString,
            "showTabsAsWindows": "false",
            "hideColoredCircles": "false",
            "windowDisplayDelay": "0",
            "coherenceDisplayDelay": "0",
            "parSameBoundaryDisplayDelayMs": "0",
            "appearanceStyle": AppearanceStylePreference.thumbnails.indexAsString,
            "appearanceSize": AppearanceSizePreference.auto.indexAsString,
            "appearanceTheme": AppearanceThemePreference.system.indexAsString,
            "theme": ThemePreference.macOs.indexAsString,
            "showOnScreen": ShowOnScreenPreference.active.indexAsString,
            "titleTruncation": TitleTruncationPreference.end.indexAsString,
            "alignThumbnails": AlignThumbnailsPreference.center.indexAsString,
            "showAppsOrWindows": ShowAppsOrWindowsPreference.windows.indexAsString,
            "showTitles": ShowTitlesPreference.windowTitle.indexAsString,
            "fadeOutAnimation": "false",
            "previewFadeInAnimation": "true",
            "startAtLogin": "true",
            "menubarIcon": MenubarIconPreference.outlined.indexAsString,
            "menubarIconShown": "true",
            "language": LanguagePreference.systemDefault.indexAsString,
            "exceptions": defaultExceptions(),
            "updatePolicy": UpdatePolicyPreference.autoCheck.indexAsString,
            "crashPolicy": CrashPolicyPreference.ask.indexAsString,
            "hideAppBadges": "false",
            "hideThumbnails": "false",
            "hideSpaceNumberLabels": "false",
            "hideStatusIcons": "false",
            "previewFocusedWindow": "false",
            "captureWindowsInBackground": "true",
            "thumbnailCaptureEnabled": "true",
            "thumbnailCaptureSettleGateEnabled": "true",
            "thumbnailUseScreenCaptureKit": "false",
            "visibleThumbnailRefreshIntervalMs": "1200",
            "thumbnailCaptureFocusSettleGateMs": "3000",
            "bgThumbnailRefreshEnabled": "true",
            "bgThumbnailHotTierSize": "10",
            "bgThumbnailHotIntervalMs": "5000",
            "bgThumbnailWarmIntervalMs": "60000",
            "bgThumbnailColdIntervalMs": "300000",
            "bgThumbnailHotJitterMs": "1000",
            "bgThumbnailWarmJitterMs": "5000",
            "bgThumbnailColdJitterMs": "30000",
            "bgThumbnailReconcileMs": "30000",
            "bgThumbnailDetachNonHotTier": "false",
            "bgThumbnailInitialMaxDelayMs": "10000",
            "bgThumbnailTickIntervalMs": "500",
            "bgThumbnailMaxPerTick": "10",
            "bgThumbnailMaxConcurrent": "4",
            "bgThumbnailPostSelectionPauseMs": "3000",
            "bgThumbnailCoherenceEnabled": "true",
            "focusOverlayCaptureEnabled": "true",
            "zOrderCacheEnabled": "true",
            "zOrderFixesEnabled": "true",
            "fastZOrderMonitorEnabled": "true",
            "fastZOrderNativeMonitorEnabled": "false",
            "fastZOrderMonitorIntervalMs": "25",
            "fastZOrderRepairFocusEnabled": "false",
            "fastZOrderRepairThrottleMs": "75",
            "fastZOrderSyntheticClickEnabled": "false",
            "parallelsTargetUserGeneratedFocusEnabled": "true",
            "parSameBoundaryTargetUserGeneratedFocusEnabled": "true",
            "parTargetAxFrontmostEnabled": "false",
            "parGuestPrefocusEnabled": "true",
            "parGuestForegroundDiagnosticsEnabled": "true",
            "parGuestForegroundReadinessEnabled": "true",
            "parGuestForegroundPollIntervalMs": "80",
            "parGuestForegroundStableMs": "60",
            "parGuestForegroundRetryIntervalMs": "140",
            "parGuestForegroundRetryMaxCount": "3",
            "skipCoherenceThumbnailsDuringPanel": "true",
            "parGuestPrefocusHostDelayMs": "20",
            "parGuestPrefocusMaxAgeMs": "220",
            "nativeNoWindowsFocusEnabled": "false",
            "nativeExperimentalFocusModesEnabled": "false",
            "zOrderEnforcementMs": "2500",
            "diagnosticsBasicPerfOnly": "false",
            "syncRefreshCoherenceTitlesBeforeShowing": "false",
            "coherenceTitleAxTimeoutMs": "60",
            "nativeFocusMode": "original",
            "nativeFocusClickFallbackEnabled": "false",
            "nativeFocusClickFallbackDelayMs": "60",
            "inputCaptureWatchdogMs": "15000",
            "inputCapturePassthroughMs": "3000",
            "parCrossBoundaryHideUiDelayMs": "200",
            "parSameBoundaryHideUiDelayMs": "30",
            "parHideMaxDelayMs": "1200",
            "parHidePollIntervalMs": "25",
            "parHideStableMs": "250",
            "parSameBoundaryHideStableMs": "250",
            "parSameBoundaryStackStableMs": "250",
            "parSameBoundaryStackStableWindowCount": "8",
            "parHideRequiresFrontmost": "true",
            "parTargetReassertDelayMs": "350",
            "parSameBoundaryReassertDelayMs": "120",
            "parTargetHardMaxDelayMs": "1600",
            "parTargetVisualReassertDelayMs": "450",
            "parTargetVisualReassertIntervalMs": "450",
            "parTargetVisualReassertMaxCount": "4",
            "parTargetAbsoluteMaxDelayMs": "600",
            "parToMacSyntheticClickEnabled": "true",
            "postAltTabFocusSuppressionMs": "2500",
            "protectNativeCommandBacktickShortcut": "false",
            "protectNativeCommandNumberShortcuts": "true",
            "screenRecordingPermissionSkipped": "false",
            "trackpadHapticFeedbackEnabled": "true",
            "settingsWindowShownOnFirstLaunch": "false",
        ]
        (0..<maxShortcutCount).forEach { index in
            values[indexToName("holdShortcut", index)] = defaultShortcut("⌥")
            values[indexToName("nextWindowShortcut", index)] = defaultShortcut(index == 0 ? "⇥" : (index == 1 ? keyAboveTabDependingOnInputSource() : ""))
        }
        (0...maxShortcutCount).forEach { index in
            values[indexToName("appsToShow", index)] = index == 1 ? AppsToShowPreference.active.indexAsString : (index == 2 ? AppsToShowPreference.nonActive.indexAsString : AppsToShowPreference.all.indexAsString)
            values[indexToName("spacesToShow", index)] = SpacesToShowPreference.all.indexAsString
            values[indexToName("screensToShow", index)] = ScreensToShowPreference.all.indexAsString
            values[indexToName("showMinimizedWindows", index)] = ShowHowPreference.showAtTheEnd.indexAsString
            values[indexToName("showHiddenWindows", index)] = ShowHowPreference.show.indexAsString
            values[indexToName("showFullscreenWindows", index)] = ShowHowPreference.show.indexAsString
            values[indexToName("showWindowlessApps", index)] = ShowHowPreference.showAtTheEnd.indexAsString
            values[indexToName("windowOrder", index)] = WindowOrderPreference.recentlyFocused.indexAsString
            values[indexToName("shortcutStyle", index)] = ShortcutStylePreference.focusOnRelease.indexAsString
        }
        return values
    }()

    // system preferences
    static var finderShowsQuitMenuItem: Bool { UserDefaults(suiteName: "com.apple.Finder")?.bool(forKey: "QuitMenuItem") ?? false }
    static let staticShortcutKeys = [
        "focusWindowShortcut", "previousWindowShortcut", "cancelShortcut", "lockSearchShortcut", "closeWindowShortcut",
        "minDeminWindowShortcut", "toggleFullscreenWindowShortcut", "quitAppShortcut", "hideShowAppShortcut", "searchShortcut",
    ]
    static var allShortcutPreferenceKeys: [String] {
        staticShortcutKeys + (0..<maxShortcutCount).flatMap { [indexToName("holdShortcut", $0), indexToName("nextWindowShortcut", $0)] }
    }
    static let emptyShortcut = Shortcut(code: .none, modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil)
    private static let shortcutStorageStringField = "string"
    private static let shortcutStorageDataField = "secureData"

    // persisted values
    static var holdShortcut: [Shortcut?] { (0..<shortcutCount).map { CachedUserDefaults.shortcut(indexToName("holdShortcut", $0)) } }
    static var nextWindowShortcut: [Shortcut?] { (0..<shortcutCount).map { CachedUserDefaults.shortcut(indexToName("nextWindowShortcut", $0)) } }
    static var nextWindowGesture: GesturePreference { CachedUserDefaults.macroPref("nextWindowGesture", GesturePreference.allCases) }
    static var focusWindowShortcut: Shortcut? { CachedUserDefaults.shortcut("focusWindowShortcut") }
    static var previousWindowShortcut: Shortcut? { CachedUserDefaults.shortcut("previousWindowShortcut") }
    static var cancelShortcut: Shortcut? { CachedUserDefaults.shortcut("cancelShortcut") }
    static var lockSearchShortcut: Shortcut? { CachedUserDefaults.shortcut("lockSearchShortcut") }
    static var closeWindowShortcut: Shortcut? { CachedUserDefaults.shortcut("closeWindowShortcut") }
    static var minDeminWindowShortcut: Shortcut? { CachedUserDefaults.shortcut("minDeminWindowShortcut") }
    static var toggleFullscreenWindowShortcut: Shortcut? { CachedUserDefaults.shortcut("toggleFullscreenWindowShortcut") }
    static var quitAppShortcut: Shortcut? { CachedUserDefaults.shortcut("quitAppShortcut") }
    static var hideShowAppShortcut: Shortcut? { CachedUserDefaults.shortcut("hideShowAppShortcut") }
    static var searchShortcut: Shortcut? { CachedUserDefaults.shortcut("searchShortcut") }
    // periphery:ignore
    static var arrowKeysEnabled: Bool { CachedUserDefaults.bool("arrowKeysEnabled") }
    // periphery:ignore
    static var vimKeysEnabled: Bool { CachedUserDefaults.bool("vimKeysEnabled") }
    static var mouseHoverEnabled: Bool { CachedUserDefaults.bool("mouseHoverEnabled") }
    static var scrollPanelOnEdgeHover: Bool { CachedUserDefaults.bool("scrollPanelOnEdgeHover") }
    static var cursorFollowFocus: CursorFollowFocus { CachedUserDefaults.macroPref("cursorFollowFocus", CursorFollowFocus.allCases) }
    static var trackpadHapticFeedbackEnabled: Bool { CachedUserDefaults.bool("trackpadHapticFeedbackEnabled") }
    static var showTabsAsWindows: Bool { CachedUserDefaults.bool("showTabsAsWindows") }
    static var hideColoredCircles: Bool { CachedUserDefaults.bool("hideColoredCircles") }
    static var windowDisplayDelay: DispatchTimeInterval { DispatchTimeInterval.milliseconds(CachedUserDefaults.int("windowDisplayDelay")) }
    static var fadeOutAnimation: Bool { CachedUserDefaults.bool("fadeOutAnimation") }
    static var previewFadeInAnimation: Bool { CachedUserDefaults.bool("previewFadeInAnimation") }
    static var hideSpaceNumberLabels: Bool { CachedUserDefaults.bool("hideSpaceNumberLabels") }
    static var hideStatusIcons: Bool { CachedUserDefaults.bool("hideStatusIcons") }
    static var hideAppBadges: Bool { CachedUserDefaults.bool("hideAppBadges") }
    // periphery:ignore
    static var startAtLogin: Bool { CachedUserDefaults.bool("startAtLogin") }
    static var exceptions: [ExceptionEntry] { CachedUserDefaults.json("exceptions", [ExceptionEntry].self) }
    static var previewSelectedWindow: Bool { CachedUserDefaults.bool("previewFocusedWindow") }
    static var captureWindowsInBackground: Bool { CachedUserDefaults.bool("captureWindowsInBackground") }
    static var screenRecordingPermissionSkipped: Bool { CachedUserDefaults.bool("screenRecordingPermissionSkipped") }
    static var settingsWindowShownOnFirstLaunch: Bool { CachedUserDefaults.bool("settingsWindowShownOnFirstLaunch") }

    // macro values
    static var appearanceStyle: AppearanceStylePreference { CachedUserDefaults.macroPref("appearanceStyle", AppearanceStylePreference.allCases) }
    static var appearanceSize: AppearanceSizePreference { CachedUserDefaults.macroPref("appearanceSize", AppearanceSizePreference.allCases) }
    static var appearanceTheme: AppearanceThemePreference { CachedUserDefaults.macroPref("appearanceTheme", AppearanceThemePreference.allCases) }
    // periphery:ignore
    static var theme: ThemePreference { ThemePreference.macOs/*CachedUserDefaults.macroPref("theme", ThemePreference.allCases)*/ }
    static var showOnScreen: ShowOnScreenPreference { CachedUserDefaults.macroPref("showOnScreen", ShowOnScreenPreference.allCases) }
    static var titleTruncation: TitleTruncationPreference { CachedUserDefaults.macroPref("titleTruncation", TitleTruncationPreference.allCases) }
    static var alignThumbnails: AlignThumbnailsPreference { CachedUserDefaults.macroPref("alignThumbnails", AlignThumbnailsPreference.allCases) }
    static var showAppsOrWindows: ShowAppsOrWindowsPreference { CachedUserDefaults.macroPref("showAppsOrWindows", ShowAppsOrWindowsPreference.allCases) }
    static var showTitles: ShowTitlesPreference { CachedUserDefaults.macroPref("showTitles", ShowTitlesPreference.allCases) }
    static var updatePolicy: UpdatePolicyPreference { CachedUserDefaults.macroPref("updatePolicy", UpdatePolicyPreference.allCases) }
    static var crashPolicy: CrashPolicyPreference { CachedUserDefaults.macroPref("crashPolicy", CrashPolicyPreference.allCases) }
    static var appsToShow: [AppsToShowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("appsToShow", $0), AppsToShowPreference.allCases) } }
    static var spacesToShow: [SpacesToShowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("spacesToShow", $0), SpacesToShowPreference.allCases) } }
    static var screensToShow: [ScreensToShowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("screensToShow", $0), ScreensToShowPreference.allCases) } }
    static var showMinimizedWindows: [ShowHowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("showMinimizedWindows", $0), ShowHowPreference.allCases) } }
    static var showHiddenWindows: [ShowHowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("showHiddenWindows", $0), ShowHowPreference.allCases) } }
    static var showFullscreenWindows: [ShowHowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("showFullscreenWindows", $0), ShowHowPreference.allCases) } }
    static var showWindowlessApps: [ShowHowPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("showWindowlessApps", $0), ShowHowPreference.allCases) } }
    static var windowOrder: [WindowOrderPreference] { (0...maxShortcutCount).map { CachedUserDefaults.macroPref(indexToName("windowOrder", $0), WindowOrderPreference.allCases) } }
    static var shortcutStyle: ShortcutStylePreference { CachedUserDefaults.macroPref("shortcutStyle", ShortcutStylePreference.allCases) }
    static var menubarIcon: MenubarIconPreference { CachedUserDefaults.macroPref("menubarIcon", MenubarIconPreference.allCases) }
    static var menubarIconShown: Bool { CachedUserDefaults.bool("menubarIconShown") }
    static var language: LanguagePreference { CachedUserDefaults.macroPref("language", LanguagePreference.allCases) }

    static let minShortcutCount = 1
    static let maxShortcutCount = 9
    static var shortcutCount: Int {
        max(minShortcutCount, min(maxShortcutCount, CachedUserDefaults.int("shortcutCount")))
    }

    static let gestureIndex = maxShortcutCount

    static func initialize() {
        PreferencesMigrations.removeCorruptedPreferences()
        PreferencesMigrations.migratePreferences()
        registerDefaults()
    }

    static func resetAll() {
        UserDefaults.standard.removePersistentDomain(forName: App.bundleIdentifier)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: defaultValues)
    }

    static func markSettingsWindowShownOnFirstLaunch() {
        set("settingsWindowShownOnFirstLaunch", "true", false)
    }

    static func defaultShortcut(_ keyEquivalent: String) -> [String: Any] {
        shortcutStorage(shortcutFromKeyEquivalent(keyEquivalent), keyEquivalent)
    }

    static func setShortcut(_ key: String, _ shortcut: Shortcut?, _ notify: Bool = true) {
        setShortcut(key, shortcut, stringRepresentation: nil, notify)
    }

    static func setShortcut(_ key: String, _ shortcut: Shortcut?, stringRepresentation: String?, _ notify: Bool = true) {
        UserDefaults.standard.set(shortcutStorage(shortcut, stringRepresentation), forKey: key)
        CachedUserDefaults.removeFromCache(key)
        if notify {
            PreferencesEvents.preferenceChanged(key)
        }
    }

    static func setShortcut(_ key: String, keyEquivalent: String, _ notify: Bool = true) {
        setShortcut(key, shortcutFromKeyEquivalent(keyEquivalent), stringRepresentation: keyEquivalent, notify)
    }

    static func shortcut(_ key: String) -> Shortcut? {
        CachedUserDefaults.shortcut(key)
    }

    static func set<T>(_ key: String, _ value: T, _ notify: Bool = true) where T: Encodable {
        UserDefaults.standard.set(key == "exceptions" ? jsonEncode(value) : value, forKey: key)
        CachedUserDefaults.removeFromCache(key)
        if notify {
            PreferencesEvents.preferenceChanged(key)
        }
    }

    static func remove(_ key: String, _ notify: Bool = true) {
        UserDefaults.standard.removeObject(forKey: key)
        CachedUserDefaults.removeFromCache(key)
        if notify {
            PreferencesEvents.preferenceChanged(key)
        }
    }

    static var all: [String: Any] { UserDefaults.standard.persistentDomain(forName: App.bundleIdentifier)! }

    static func onlyShowApplications() -> Bool {
        return Preferences.showAppsOrWindows == .applications && Preferences.appearanceStyle != .thumbnails
    }

    /// key-above-tab is ` on US keyboard, but can be different on other keyboards
    static func keyAboveTabDependingOnInputSource() -> String {
        return LiteralKeyCodeTransformer.shared.transformedValue(NSNumber(value: kVK_ANSI_Grave)) ?? "`"
    }

    static func returnKeyEquivalent() -> String {
        return LiteralKeyCodeTransformer.shared.transformedValue(NSNumber(value: kVK_Return)) ?? "↩"
    }

    static func defaultExceptions() -> String {
        return jsonEncode([
            ExceptionEntry(bundleIdentifier: "com.McAfee.McAfeeSafariHost", hide: .always, ignore: .none),
            ExceptionEntry(bundleIdentifier: "com.apple.finder", hide: .whenNoOpenWindow, ignore: .none),
        ] + [
            "com.microsoft.rdc.macos",
            "com.teamviewer.TeamViewer",
            "org.virtualbox.app.VirtualBoxVM",
            "com.parallels.",
            "com.citrix.XenAppViewer",
            "com.citrix.receiver.icaviewer.mac",
            "com.nicesoftware.dcvviewer",
            "com.vmware.fusion",
            "com.apple.ScreenSharing",
            "com.utmapp.UTM",
        ].map {
            ExceptionEntry(bundleIdentifier: $0, hide: .none, ignore: .whenFullscreen)
        })
    }

    static func jsonEncode<T>(_ value: T) -> String where T: Encodable {
        return String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    static func archiveShortcut(_ shortcut: Shortcut?) -> Data {
        if #available(macOS 10.13, *) {
            return try! NSKeyedArchiver.archivedData(withRootObject: shortcut ?? emptyShortcut, requiringSecureCoding: true)
        }
        return NSKeyedArchiver.archivedData(withRootObject: shortcut ?? emptyShortcut)
    }

    static func shortcutStorage(_ shortcut: Shortcut?, _ stringRepresentation: String?) -> [String: Any] {
        [
            shortcutStorageStringField: stringRepresentation ?? shortcut?.readableStringRepresentation(isASCII: true) ?? "",
            shortcutStorageDataField: archiveShortcut(shortcut),
        ]
    }

    static func decodeShortcutStorage(_ value: Any) -> (Bool, Shortcut?) {
        guard let storage = value as? [String: Any], let data = storage[shortcutStorageDataField] as? Data else { return (false, nil) }
        return unarchiveShortcut(data)
    }

    static func unarchiveShortcut(_ data: Data) -> (Bool, Shortcut?) {
        let shortcut: Shortcut?
        if #available(macOS 10.13, *) {
            shortcut = try? NSKeyedUnarchiver.unarchivedObject(ofClass: Shortcut.self, from: data)
        } else {
            shortcut = NSKeyedUnarchiver.unarchiveObject(with: data) as? Shortcut
        }
        guard let shortcut else { return (false, nil) }
        return (true, shortcut.keyCode == .none && shortcut.modifierFlags == [] ? nil : shortcut)
    }

    static func shortcutFromKeyEquivalent(_ keyEquivalent: String) -> Shortcut? {
        keyEquivalent.isEmpty ? nil : Shortcut(keyEquivalent: keyEquivalent)
    }

    static func indexToName(_ baseName: String, _ index: Int) -> String {
        return baseName + (index == 0 ? "" : String(index + 1))
    }

    static func nameToIndex(_ name: String) -> Int {
        let digits = String(name.reversed().prefix { $0.isNumber }.reversed())
        guard !digits.isEmpty, let number = Int(digits) else { return 0 }
        return number - 1
    }
}

class CachedUserDefaults {
    static var cache = ConcurrentMap<String, Any>()

    static func removeFromCache(_ key: String) {
        cache.withLock { $0.removeValue(forKey: key) }
    }

    /// retrieve strings in the globalDomain (e.g. defaults read -g KeyRepeat)
    /// these may be nil since we they don't have default values from AltTab
    static func globalString(_ key: String) -> String? {
        if let cached = cache.withLock({ $0[key] }) {
            return cached as? String
        }
        if let string = UserDefaults.standard.string(forKey: key) {
            cache.withLock { $0[key] = string }
        }
        return nil
    }

    static func string(_ key: String) -> String {
        if let cachedFinalValue = cache.withLock({ $0[key] }) {
            return cachedFinalValue as! String
        }
        let finalValue = UserDefaults.standard.string(forKey: key)!
        cache.withLock { $0[key] = finalValue }
        return finalValue
    }

    static func shortcut(_ key: String) -> Shortcut? {
        if let cachedFinalValue = cache.withLock({ $0[key] }) {
            return cachedFinalValue as? Shortcut
        }
        guard let objectValue = UserDefaults.standard.object(forKey: key) else {
            cache.withLock { $0[key] = NSNull() }
            return nil
        }
        let (isValid, finalValue) = Preferences.decodeShortcutStorage(objectValue)
        if isValid {
            cache.withLock { $0[key] = finalValue ?? NSNull() }
            return finalValue
        }
        UserDefaults.standard.removeObject(forKey: key)
        return shortcut(key)
    }

    static func int(_ key: String) -> Int {
        return getThenConvertOrReset(key, { s in Int(s) })
    }

    static func bool(_ key: String) -> Bool {
        return getThenConvertOrReset(key, { s in Bool(s) })
    }

    static func double(_ key: String) -> Double {
        return getThenConvertOrReset(key, { s in Double(s) })
    }

    static func macroPref<A>(_ key: String, _ macroPreferences: [A]) -> A {
        return getThenConvertOrReset(key, { s in Int(s).flatMap { macroPreferences[safe: $0] } })
    }

    /// some UI elements (e.g. dropdown, radios) need an int. We find the right int from the MacroPreference index
    static func intFromMacroPref(_ key: String, _ macroPreferences: [MacroPreference]) -> Int {
        let macroPref = macroPref(key, macroPreferences)
        return macroPreferences.firstIndex { $0.localizedString == macroPref.localizedString }!
    }

    static func json<T>(_ key: String, _ type: T.Type) -> T where T: Decodable {
        return getThenConvertOrReset(key, { s in jsonDecode(s, type) })
    }

    private static func getThenConvertOrReset<T>(_ key: String, _ getterFn: (String) -> T?) -> T {
        if let cachedFinalValue = cache.withLock({ $0[key] }) {
            return cachedFinalValue as! T
        }
        let stringValue = UserDefaults.standard.string(forKey: key)!
        if let finalValue = getterFn(stringValue) {
            cache.withLock { $0[key] = finalValue }
            return finalValue
        }
        // value couldn't be read properly; we remove it and work with the default
        UserDefaults.standard.removeObject(forKey: key)
        let defaultStringValue = UserDefaults.standard.string(forKey: key)!
        let defaultFinalValue = getterFn(defaultStringValue)!
        cache.withLock { $0[key] = defaultFinalValue }
        return defaultFinalValue
    }

    private static func jsonDecode<T>(_ value: String, _ type: T.Type) -> T? where T: Decodable {
        return value.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

enum RuntimeFlags {
    static var diagnosticsBasicPerfOnly: Bool { bool("diagnosticsBasicPerfOnly", default: false) }
    static var thumbnailCaptureEnabled: Bool { bool("thumbnailCaptureEnabled", default: true) }
    static var thumbnailCaptureSettleGateEnabled: Bool { bool("thumbnailCaptureSettleGateEnabled", default: true) }
    static var thumbnailUseScreenCaptureKit: Bool { bool("thumbnailUseScreenCaptureKit", default: false) }
    static var visibleThumbnailRefreshIntervalMs: Int { int("visibleThumbnailRefreshIntervalMs", default: 1200) }
    static var thumbnailCaptureFocusSettleGateMs: Int { int("thumbnailCaptureFocusSettleGateMs", default: 3000) }
    static var focusOverlayCaptureEnabled: Bool { bool("focusOverlayCaptureEnabled", default: true) }
    static var zOrderCacheEnabled: Bool { bool("zOrderCacheEnabled", default: true) }
    static var zOrderFixesEnabled: Bool { bool("zOrderFixesEnabled", default: true) }
    static var fastZOrderMonitorEnabled: Bool { bool("fastZOrderMonitorEnabled", default: true) }
    static var fastZOrderNativeMonitorEnabled: Bool { bool("fastZOrderNativeMonitorEnabled", default: false) }
    static var fastZOrderMonitorIntervalMs: Int { int("fastZOrderMonitorIntervalMs", default: 25) }
    static var fastZOrderRepairFocusEnabled: Bool { bool("fastZOrderRepairFocusEnabled", default: false) }
    static var fastZOrderRepairThrottleMs: Int { int("fastZOrderRepairThrottleMs", default: 75) }
    static var fastZOrderSyntheticClickEnabled: Bool { bool("fastZOrderSyntheticClickEnabled", default: false) }
    static var parallelsTargetUserGeneratedFocusEnabled: Bool { bool("parallelsTargetUserGeneratedFocusEnabled", default: true) }
    static var parSameBoundaryTargetUserGeneratedFocusEnabled: Bool { bool("parSameBoundaryTargetUserGeneratedFocusEnabled", default: true) }
    static var parTargetAxFrontmostEnabled: Bool { bool("parTargetAxFrontmostEnabled", default: false) }
    static var parGuestPrefocusEnabled: Bool { bool("parGuestPrefocusEnabled", default: true) }
    static var parGuestForegroundDiagnosticsEnabled: Bool { bool("parGuestForegroundDiagnosticsEnabled", default: true) }
    static var parGuestForegroundReadinessEnabled: Bool { bool("parGuestForegroundReadinessEnabled", default: true) }
    static var parGuestForegroundPollIntervalMs: Int { int("parGuestForegroundPollIntervalMs", default: 80) }
    static var parGuestForegroundStableMs: Int { int("parGuestForegroundStableMs", default: 60) }
    static var parGuestForegroundRetryIntervalMs: Int { int("parGuestForegroundRetryIntervalMs", default: 140) }
    static var parGuestForegroundRetryMaxCount: Int { int("parGuestForegroundRetryMaxCount", default: 3) }
    static var skipCoherenceThumbnailsDuringPanel: Bool { bool("skipCoherenceThumbnailsDuringPanel", default: true) }
    static var parGuestPrefocusHostDelayMs: Int { int("parGuestPrefocusHostDelayMs", default: 20) }
    static var parGuestPrefocusMaxAgeMs: Int { int("parGuestPrefocusMaxAgeMs", default: 220) }
    static var nativeNoWindowsFocusEnabled: Bool { bool("nativeNoWindowsFocusEnabled", default: false) }
    static var nativeExperimentalFocusModesEnabled: Bool { bool("nativeExperimentalFocusModesEnabled", default: false) }
    static var zOrderEnforcementMs: Int { int("zOrderEnforcementMs", default: 2500) }
    static var syncRefreshCoherenceTitlesBeforeShowing: Bool { bool("syncRefreshCoherenceTitlesBeforeShowing", default: false) }
    static var coherenceTitleAxTimeoutMs: Int { int("coherenceTitleAxTimeoutMs", default: 60) }
    static var nativeFocusClickFallbackEnabled: Bool { bool("nativeFocusClickFallbackEnabled", default: false) }
    static var nativeFocusClickFallbackDelayMs: Int { int("nativeFocusClickFallbackDelayMs", default: 60) }
    static var inputCaptureWatchdogMs: Int { int("inputCaptureWatchdogMs", default: 15000) }
    static var inputCapturePassthroughMs: Int { int("inputCapturePassthroughMs", default: 3000) }
    static var parCrossBoundaryHideUiDelayMs: Int { int("parCrossBoundaryHideUiDelayMs", default: 200) }
    static var parSameBoundaryHideUiDelayMs: Int { int("parSameBoundaryHideUiDelayMs", default: 30) }
    static var parHideMaxDelayMs: Int { int("parHideMaxDelayMs", default: 1200) }
    static var parHidePollIntervalMs: Int { int("parHidePollIntervalMs", default: 25) }
    static var parHideStableMs: Int { int("parHideStableMs", default: 250) }
    static var parSameBoundaryDisplayDelayMs: Int { int("parSameBoundaryDisplayDelayMs", default: 0) }
    static var parSameBoundaryHideStableMs: Int { int("parSameBoundaryHideStableMs", default: 250) }
    static var parSameBoundaryStackStableMs: Int { int("parSameBoundaryStackStableMs", default: 250) }
    static var parSameBoundaryStackStableWindowCount: Int { int("parSameBoundaryStackStableWindowCount", default: 8) }
    static var parHideRequiresFrontmost: Bool { bool("parHideRequiresFrontmost", default: true) }
    static var parTargetReassertDelayMs: Int { int("parTargetReassertDelayMs", default: 350) }
    static var parSameBoundaryReassertDelayMs: Int { int("parSameBoundaryReassertDelayMs", default: 120) }
    static var parTargetHardMaxDelayMs: Int { int("parTargetHardMaxDelayMs", default: 1600) }
    static var parTargetVisualReassertDelayMs: Int { int("parTargetVisualReassertDelayMs", default: 450) }
    static var parTargetVisualReassertIntervalMs: Int { int("parTargetVisualReassertIntervalMs", default: 450) }
    static var parTargetVisualReassertMaxCount: Int { int("parTargetVisualReassertMaxCount", default: 4) }
    static var parTargetAbsoluteMaxDelayMs: Int { int("parTargetAbsoluteMaxDelayMs", default: 600) }
    /// When host-side parHide evidence (target at z0, frontmost, stable) has
    /// held for at least this many ms past the required stable threshold,
    /// drop the guest.ready requirement and fire parHideNow. Mitigates the
    /// case where guest title-matching fails (e.g., Outlook reports
    /// inbox-specific titles) and every Coherence switch eats the full
    /// `parTargetAbsoluteMaxDelayMs` (~1.8s) timeout.
    static var parGuestBypassHostStableMs: Int { int("parGuestBypassHostStableMs", default: 0) }
    /// Post a synthetic SkyLight click on the target Mac window when
    /// switching from Parallels Coherence to a native macOS window. SLPS
    /// alone makes the target frontmost but doesn't always trigger full
    /// NSApp activation — without the click, traffic-light buttons stay
    /// grey and the user perceives the app as inactive. Browsers
    /// (Chrome/Safari/Edge/Firefox/etc.) are in
    /// `parToMacSyntheticClickUnsafeBundlePrefixes` and skip the click
    /// because synthetic clicks can accidentally activate links/buttons.
    static var parToMacSyntheticClickEnabled: Bool { bool("parToMacSyntheticClickEnabled", default: true) }
    static var postAltTabFocusSuppressionMs: Int { int("postAltTabFocusSuppressionMs", default: 2500) }
    static var protectNativeCommandBacktickShortcut: Bool { bool("protectNativeCommandBacktickShortcut", default: false) }
    static var protectNativeCommandNumberShortcuts: Bool { bool("protectNativeCommandNumberShortcuts", default: true) }
    static var bgThumbnailRefreshEnabled: Bool { bool("bgThumbnailRefreshEnabled", default: true) }
    static var bgThumbnailHotTierSize: Int { int("bgThumbnailHotTierSize", default: 10) }
    static var bgThumbnailHotIntervalMs: Int { int("bgThumbnailHotIntervalMs", default: 5000) }
    static var bgThumbnailWarmIntervalMs: Int { int("bgThumbnailWarmIntervalMs", default: 60000) }
    static var bgThumbnailColdIntervalMs: Int { int("bgThumbnailColdIntervalMs", default: 300000) }
    static var bgThumbnailHotJitterMs: Int { int("bgThumbnailHotJitterMs", default: 1000) }
    static var bgThumbnailWarmJitterMs: Int { int("bgThumbnailWarmJitterMs", default: 5000) }
    static var bgThumbnailColdJitterMs: Int { int("bgThumbnailColdJitterMs", default: 30000) }
    /// How often the background refresher reconciles its window list against
    /// the live WindowServer window list (zombie GC), releasing thumbnails
    /// (and their IOSurfaces) for windows that closed without an AX-destroyed
    /// event. Previously this only ran on panel-show.
    static var bgThumbnailReconcileMs: Int { int("bgThumbnailReconcileMs", default: 30000) }
    /// Default OFF: thumbnails are kept as live IOSurface-backed bitmaps (GPU-resident, so the
    /// first paint after idle is fast — malloc bitmaps get memory-compressed while idle and are
    /// slow to fault+re-upload cold). The IOSurface budget is instead bounded by the lifecycle
    /// fixes (unregister-on-close, the 30s zombie-GC reconcile, the in-flight watchdog), so the
    /// surface count tracks the live-window count rather than growing unbounded — that unbounded
    /// growth (leaked surfaces for closed windows over a multi-day session), not the per-window
    /// surface, is what crashed WindowServer. Watch the `surfaces`/`windows` counts in the
    /// THUMBCACHE log. Set true to fall back to detaching non-hot captures into malloc bitmaps
    /// (releases the IOSurface immediately) if the surface count ever creeps up.
    static var bgThumbnailDetachNonHotTier: Bool { bool("bgThumbnailDetachNonHotTier", default: false) }
    static var bgThumbnailInitialMaxDelayMs: Int { int("bgThumbnailInitialMaxDelayMs", default: 10000) }
    static var bgThumbnailTickIntervalMs: Int { int("bgThumbnailTickIntervalMs", default: 500) }
    static var bgThumbnailMaxPerTick: Int { int("bgThumbnailMaxPerTick", default: 10) }
    static var bgThumbnailMaxConcurrent: Int { int("bgThumbnailMaxConcurrent", default: 4) }
    static var bgThumbnailPostSelectionPauseMs: Int { int("bgThumbnailPostSelectionPauseMs", default: 3000) }
    static var bgThumbnailCoherenceEnabled: Bool { bool("bgThumbnailCoherenceEnabled", default: true) }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) else { return defaultValue }
        if let boolValue = value as? Bool { return boolValue }
        if let numberValue = value as? NSNumber { return numberValue.boolValue }
        if let stringValue = value as? String { return Bool(stringValue) ?? defaultValue }
        return defaultValue
    }

    private static func int(_ key: String, default defaultValue: Int) -> Int {
        guard let value = UserDefaults.standard.object(forKey: key) else { return defaultValue }
        if let intValue = value as? Int { return intValue }
        if let numberValue = value as? NSNumber { return numberValue.intValue }
        if let stringValue = value as? String { return Int(stringValue) ?? defaultValue }
        return defaultValue
    }
}

struct ExceptionEntry: Codable {
    var bundleIdentifier: String
    var hide: ExceptionHidePreference
    var ignore: ExceptionIgnorePreference
    var windowTitleContains: String?
}
