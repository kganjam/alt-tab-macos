import Cocoa
import ScreenCaptureKit

@available(macOS 14.0, *)
class WindowCaptureScreenshots {
    // SCShareableContent.getExcludingDesktopWindows is expensive for the OS; we cache as much as
    // possible. This cache is touched from the (concurrent, 2-wide) screenshotsQueue, from the main
    // thread (screen-change invalidation via ScreensEvents), and from the permission-check path — so
    // every access goes through `cacheLock`. A plain `static var` here is a data race (Array CoW
    // corruption / crash), most likely during display reconfiguration when capture traffic is heavy.
    private static let cacheLock = NSLock()
    private static var cachedSCWindows = [SCWindow]()

    static func setCachedWindows(_ windows: [SCWindow]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedSCWindows = windows
    }

    static func invalidateCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedSCWindows.removeAll(keepingCapacity: true)
    }

    private static func invalidateCache(_ wid: CGWindowID) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedSCWindows.removeAll { $0.windowID == wid }
    }

    private static func lookupCachedWindow(_ wid: CGWindowID) -> SCWindow? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cachedSCWindows.first { $0.windowID == wid }
    }

    /// Per-window state snapshotted on the main thread before the (concurrent) screenshots queue runs.
    struct CaptureRequest {
        let window: Window
        let size: CGSize
        let scaleFactor: CGFloat
    }

    /// MUST be called on the main thread. We snapshot Window.size / scale factor / the Window ref here
    /// before hopping to the concurrent screenshotsQueue. Window.size, Window.screenId, Screens.all and
    /// NSScreen.preferred are main-thread-owned; reading them from the screenshots queue races with
    /// main-thread mutation and can corrupt the heap (the crash class upstream lwouis fixed in f4a54c8f,
    /// which our own audit independently flagged). Size is fixed at call time, so a window resized between
    /// snapshot and capture is captured at the old size and corrected on the next refresh.
    static func oneTimeScreenshots(_ windowsToScreenshot: [Window], _ source: RefreshCausedBy) {
        guard RuntimeFlags.thumbnailCaptureEnabled, App.thumbnailCaptureAllowed(source) else { return }
        var requests = [CGWindowID: CaptureRequest]()
        for window in windowsToScreenshot {
            guard let wid = window.cgWindowId, let size = window.size else { continue }
            let scaleFactor: CGFloat
            if let screenId = window.screenId, let screen = Screens.all[screenId] {
                scaleFactor = screen.backingScaleFactor
            } else {
                scaleFactor = NSScreen.preferred.backingScaleFactor
            }
            requests[wid] = CaptureRequest(window: window, size: size, scaleFactor: scaleFactor)
        }
        guard !requests.isEmpty else { return }
        BackgroundWork.screenshotsQueue.addOperation {
            guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
            guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
            let (cachedWindows, notCachedWindows) = sortCachedAndNotCached(Array(requests.keys))
            Logger.debug { "cached:\(cachedWindows.map { $0.windowID }) notCached:\(notCachedWindows)" }
            handleCachedWindows(cachedWindows, requests, source)
            handleNotCachedWindows(notCachedWindows, requests, source)
        }
    }

    private static func handleCachedWindows(_ cachedWindows: [SCWindow], _ requests: [CGWindowID: CaptureRequest], _ source: RefreshCausedBy) {
        guard !cachedWindows.isEmpty else { return }
        for cachedWindow in cachedWindows {
            guard let request = requests[cachedWindow.windowID] else { continue }
            oneTimeCapture(cachedWindow, request, source)
        }
    }

    private static func handleNotCachedWindows(_ notCachedWindows: [CGWindowID], _ requests: [CGWindowID: CaptureRequest], _ source: RefreshCausedBy) {
        guard !notCachedWindows.isEmpty else { return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { shareableContent, error in
            guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
            guard let shareableContent, error == nil else { Logger.error { "\(shareableContent == nil) \(error)" }; return }
            guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
            // this callback runs on an undetermined queue; hop to screenshotsQueue to mutate the cache
            BackgroundWork.screenshotsQueue.addOperation {
                guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
                setCachedWindows(shareableContent.windows)
                guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
                for notCachedWindow in notCachedWindows {
                    guard let request = requests[notCachedWindow] else { continue }
                    if let cachedWindow = lookupCachedWindow(notCachedWindow) {
                        oneTimeCapture(cachedWindow, request, source)
                    } else {
                        Logger.debug { "wid:\(notCachedWindow) was not found in SCShareableContent windows" }
                    }
                }
            }
        }
    }

    private static func sortCachedAndNotCached(_ windows: [CGWindowID]) -> ([SCWindow], [CGWindowID]) {
        var cachedWindows = [SCWindow]()
        var notCachedWindows = [CGWindowID]()
        for window in windows {
            if let cachedWindow = lookupCachedWindow(window) {
                cachedWindows.append(cachedWindow)
            } else {
                notCachedWindows.append(window)
            }
        }
        return (cachedWindows, notCachedWindows)
    }

    private static func oneTimeCapture(_ scWindow: SCWindow, _ request: CaptureRequest, _ source: RefreshCausedBy) {
        guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
        guard !App.isTerminating else { return }
        // window/size/scaleFactor came from the main-thread snapshot (CaptureRequest) — no Windows.list
        // or Window.size reads here on the concurrent screenshots queue.
        let window = request.window
        let config = SCStreamConfiguration.forWindow(size: request.size, scaleFactor: request.scaleFactor, false)
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        CaptureBackendCounters.countSck()
        let captureToken = ActiveWindowCaptures.begin()
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { sampleBuffer, error in
            ActiveWindowCaptures.end(captureToken)
            guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
            guard let sampleBuffer, error == nil else {
                Logger.error { "\(window.debugId) \(sampleBuffer == nil) \(error)" }
                BackgroundWork.screenshotsQueue.addOperation {
                    invalidateCache(scWindow.windowID)
                    WindowCaptureScreenshotsPrivateApi.oneTimeScreenshots([window], source)
                }
                return
            }
            guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
            let pixelBuffer: CVPixelBuffer? = sampleBuffer.pixelBuffer() ?? sampleBuffer.imageBuffer
            guard let pixelBuffer else { Logger.error { "\(window.debugId) no pixelBuffer" }; return }
            // For non-hot background captures, detach into a malloc-backed
            // bitmap here (off the main thread) so the WindowServer capture
            // IOSurface is released rather than retained live in the cache.
            let contents: CALayerContents
            let liveSurface: Bool
            if ThumbnailBitmap.shouldDetach(source, wid: scWindow.windowID),
               let detached = ThumbnailBitmap.detachedCopy(of: pixelBuffer) {
                contents = .cgImage(detached)
                liveSurface = false // malloc-backed copy; the WindowServer IOSurface was released
            } else {
                contents = .pixelBuffer(pixelBuffer)
                liveSurface = true // IOSurface-backed pixel buffer kept live in the cache
            }
            DispatchQueue.main.async {
                guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
                guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
                if let window = (Windows.list.first { $0.cgWindowId == scWindow.windowID }) {
                    window.refreshThumbnail(contents, liveSurface: liveSurface)
                }
            }
        }
    }
}

class WindowCaptureScreenshotsPrivateApi {
    static func oneTimeScreenshots(_ eligibleWindows: [Window], _ source: RefreshCausedBy) {
        guard RuntimeFlags.thumbnailCaptureEnabled, App.thumbnailCaptureAllowed(source) else { return }
        for window in eligibleWindows {
            BackgroundWork.screenshotsQueue.addOperation { [weak window] in
                guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
                guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
                guard let wid = window?.cgWindowId, let cgImage = oneTimeCapture(wid, source) else { return }
                guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
                guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
                // Detach non-hot background captures off-main so the HW capture
                // IOSurface (CGSHWCaptureWindowList output) is released.
                let contents: CALayerContents
                let liveSurface: Bool
                if ThumbnailBitmap.shouldDetach(source, wid: wid),
                   let detached = ThumbnailBitmap.detachedCopy(of: cgImage) {
                    contents = .cgImage(detached)
                    liveSurface = false // malloc-backed copy; the HW-capture IOSurface was released
                } else {
                    contents = .cgImage(cgImage)
                    liveSurface = true // IOSurface-backed CGImage (CGSHWCaptureWindowList output) kept live
                }
                DispatchQueue.main.async { [weak window] in
                    guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return }
                    guard !source.requiresOpenPanel || App.appIsBeingUsed else { return }
                    window?.refreshThumbnail(contents, liveSurface: liveSurface)
                }
            }
        }
    }

    private static func oneTimeCapture(_ wid: CGWindowID, _ source: RefreshCausedBy) -> CGImage? {
        guard App.thumbnailCaptureAllowed(source, logBlocked: false) else { return nil }
        guard !App.isTerminating else { return nil }
        // we use CGSHWCaptureWindowList because it can screenshot minimized windows, which CGWindowListCreateImage can't
        var windowId_ = wid
        CaptureBackendCounters.countCgs()
        let captureToken = ActiveWindowCaptures.begin()
        defer { ActiveWindowCaptures.end(captureToken) }
        // CGSHWCaptureWindowList can return NULL (window vanished, or a Coherence/offscreen window
        // WindowServer can't capture) and is not guaranteed to box CGImages — guard instead of
        // force-unwrapping `.takeRetainedValue()` / force-casting `as!`, both of which would crash.
        guard let captured = CGSHWCaptureWindowList(CGS_CONNECTION, &windowId_, 1, [.ignoreGlobalClipShape, .bestResolution, .fullSize])?.takeRetainedValue(),
              let images = captured as? [CGImage] else { return nil }
        return images.first
    }
}

// @available(macOS 12.3, *)
// class WindowCaptureVideos {
//     private static var streams = [CGWindowID: SCStream]()
//     private static var streamOutputs = [CGWindowID: StreamOutput]()
//     // SCStream.backgroundColor is [unowned], so we must keep own these variables
//     static let scStreamBackgroundColorDark = NSColor(white: 0.23, alpha: 1).cgColor
//     static let scStreamBackgroundColorLight = NSColor.white.cgColor
//
//     static func startCapturing(_ windowsWhichMayHaveChanged: [Window]) {
//         let windowsToShow = Set<CGWindowID>(Windows.list.filter { !$0.isWindowlessApp && $0.shouldShowTheUser }.compactMap { $0.cgWindowId })
//         let windowsAlreadyStreaming = Set<CGWindowID>(streams.keys)
//         let windowsToStop = windowsAlreadyStreaming.subtracting(windowsToShow)
//         stopCaptures(windowsToStop)
//         let windowsToStart = windowsToShow.subtracting(windowsAlreadyStreaming)
//         let windowsWhichMayHaveChanged_ = windowsWhichMayHaveChanged.compactMap { $0.cgWindowId }
//         if !windowsToStart.isEmpty || !windowsWhichMayHaveChanged_.isEmpty {
//             SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { shareableContent, error in
//                 guard let shareableContent, error == nil else {
//                     Logger.error { "\(shareableContent == nil) \(error)" }
//                     return
//                 }
//                 // this callback is executed on an undetermined queue
//                 // we move execution to main-thread to avoid races with starting/stopping streams and the app being shown/hidden
//                 DispatchQueue.main.async {
//                     guard App.appIsBeingUsed else { return }
//                     startCaptures(windowsToStart, shareableContent)
//                     updateCaptures(windowsWhichMayHaveChanged_, shareableContent)
//                     Logger.debug { streams.keys }
//                 }
//             }
//         }
//     }
//
//     static func stopCapturing() {
//         Logger.debug { streams.keys }
//         for stream in streams.values {
//             stream.stopCapture()
//         }
//         streams.removeAll()
//         streamOutputs.removeAll()
//     }
//
//     private static func updateCaptures(_ windowsWhichMayHaveChanged: [CGWindowID], _ shareableContent: SCShareableContent) {
//         for wid in windowsWhichMayHaveChanged {
//             if let stream = streams[wid],
//                let scWindow = shareableContent.windows.first(where: { $0.windowID == wid }) {
//                 stream.updateConfiguration(SCStreamConfiguration.forWindow(scWindow, true)) { error in
//                     if let error { Logger.error { error } }
//                 }
//             }
//         }
//     }
//
//     private static func startCaptures(_ windowsToStart: Set<CGWindowID>, _ shareableContent: SCShareableContent) {
//         for wid in windowsToStart {
//             if let scWindow = shareableContent.windows.first(where: { $0.windowID == wid }) {
//                 startCapture(scWindow)
//             }
//         }
//     }
//
//
//     private static func startCapture(_ window: SCWindow) {
//         let wid = window.windowID
//         let output = StreamOutput(wid)
//         let config = SCStreamConfiguration.forWindow(window, true)
//         let filter = SCContentFilter(desktopIndependentWindow: window)
//         let stream = SCStream(filter: filter, configuration: config, delegate: output)
//         do {
//             try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: BackgroundWork.screenshotsQueue.strongUnderlyingQueue)
//             stream.startCapture { error in
//                 if let error { Logger.error { error } }
//             }
//             streams[wid] = stream
//             streamOutputs[wid] = output
//         } catch {
//             Logger.error { error }
//         }
//     }
//
//     private static func stopCaptures(_ windowsToStop: Set<CGWindowID>) {
//         for wid in windowsToStop {
//             stopCapture(wid)
//         }
//     }
//
//     private static func stopCapture(_ wid: CGWindowID) {
//         if let stream = streams[wid] {
//             stream.stopCapture()
//             streams.removeValue(forKey: wid)
//             streamOutputs.removeValue(forKey: wid)
//         }
//     }
//
//     class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
//         let wid: CGWindowID
//
//         init(_ wid: CGWindowID) {
//             self.wid = wid
//         }
//
//         // from SCStreamOutput; handle captured samples
//         func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
//             BackgroundWork.screenshotsQueue.trackCallbacks {
//                 if sampleBuffer.isValid,
//                    let pixelBuffer = sampleBuffer.pixelBuffer() {
//                     DispatchQueue.main.async {
//                         if let window = (Windows.list.first { $0.cgWindowId == self.wid }) {
//                             window.refreshThumbnail(.pixelBuffer(pixelBuffer))
//                         }
//                     }
//                 }
//             }
//         }
//
//         // from SCStreamDelegate; handle errors when opening a stream
//         func stream(_ stream: SCStream, didStopWithError error: any Error) {
//             BackgroundWork.screenshotsQueue.trackCallbacks {
//                 Logger.error { error }
//             }
//         }
//     }
// }

@available(macOS 12.3, *)
extension SCStreamConfiguration {
    static func forWindow(size: CGSize, scaleFactor: CGFloat, _ video: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.setWindowSize(size: size, scaleFactor: scaleFactor)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        // if video {
        //     config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(60))
        //     config.queueDepth = 8
        //     // ~60% memory reduction compared to kCVPixelFormatType_32BGRA
        //     config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        //     // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange doesn't have transparency, so we end up with an opaque background color around the window corners
        //     // we use a background color that try and hide these corners as much as possible
        //     config.backgroundColor = Appearance.currentTheme == .dark ? WindowCaptureVideos.scStreamBackgroundColorDark : WindowCaptureVideos.scStreamBackgroundColorLight
        // }
        // config.scalesToFit = true
        return config
    }

    private func setWindowSize(size: CGSize, scaleFactor: CGFloat) {
        // size (logical) and scaleFactor were snapshotted on the main thread by the caller. We use the
        // window's logical size (not scWindow.frame, which is cached/stale) corrected for DPI so we
        // capture the right pixel count.
        let originalSize = NSSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
        guard originalSize.width > 0, originalSize.height > 0 else { return }
        if Preferences.previewSelectedWindow {
            width = Int(originalSize.width)
            height = Int(originalSize.height)
        } else {
            // capture screenshots as small as needed for the thumbnails
            let maxSize = TilesPanel.maxPossibleThumbnailSize
            guard maxSize.width > 0, maxSize.height > 0 else { return }
            let scale = min(1.0, maxSize.width / originalSize.width, maxSize.height / originalSize.height)
            width = Int((originalSize.width * scale).rounded())
            height = Int((originalSize.height * scale).rounded())
        }
    }
}

extension CMSampleBuffer {
    @available(macOS 12.3, *)
    func pixelBuffer() -> CVPixelBuffer? {
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRawValue),
           status == .complete || status == .started { // new frame was generated
            return imageBuffer
        }
        return nil
    }

    @available(macOS 12.3, *)
    func metalTexture(_ device: MTLDevice) -> MTLTexture? {
        guard let pixelBuffer = pixelBuffer(),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            mipmapped: false
        )
        return device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
    }
}

/// Tracks in-flight captures for the refresher's back-pressure gate.
/// Token-based with a watchdog: `value()` prunes tokens older than
/// `timeoutSec` before returning the count, so a capture whose completion
/// never fires (e.g. WindowServer wedged after a crash) can't permanently
/// jam back-pressure. The previous raw atomic counter had no expiry — a
/// single never-firing SCK completion would leak the count and block all
/// background thumbnails until AltTab was relaunched.
class ActiveWindowCaptures {
    private static let lock = NSLock()
    private static var inFlight = [UInt64: CFAbsoluteTime]()
    private static var counter: UInt64 = 0
    private static let timeoutSec: CFAbsoluteTime = 20

    @discardableResult
    static func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        inFlight[counter] = CFAbsoluteTimeGetCurrent()
        return counter
    }

    static func end(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        inFlight.removeValue(forKey: token)
    }

    static func value() -> Int {
        lock.lock(); defer { lock.unlock() }
        if !inFlight.isEmpty {
            let cutoff = CFAbsoluteTimeGetCurrent() - timeoutSec
            inFlight = inFlight.filter { $0.value > cutoff }
        }
        return inFlight.count
    }
}

/// Cumulative per-backend capture counters for the THUMBCACHE diagnostic line.
/// The `cgs` count is the one that matters for the WindowServer crash: it's how
/// many times AltTab has called the private CGSHWCaptureWindowList API, which
/// feeds WindowServer's capture-IOSurface tally (WSIOSurfaceDebugTallyAndAbort).
/// Watch its per-interval delta — with `thumbnailUseScreenCaptureKit` on it
/// should be ~Coherence+minimized only, not the whole window set. A `cgs` rate
/// that tracks the total window count means native captures are NOT going
/// through ScreenCaptureKit (the SCK routing regressed).
enum CaptureBackendCounters {
    private static let lock = NSLock()
    private static var cgs: UInt64 = 0
    private static var sck: UInt64 = 0
    static func countCgs() { lock.lock(); cgs &+= 1; lock.unlock() }
    static func countSck() { lock.lock(); sck &+= 1; lock.unlock() }
    static func snapshot() -> (cgs: UInt64, sck: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (cgs, sck)
    }
}

/// Copies a captured image into a detached, malloc-backed `CGImage` so the
/// WindowServer capture IOSurface backing the original can be released. Used
/// for non-hot-tier background captures to bound the count of outstanding
/// capture surfaces — WindowServer aborts (crashing the whole session) when a
/// client exceeds its IOSurface tally (`WSIOSurfaceDebugTallyAndAbort`).
enum ThumbnailBitmap {
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Detach an (often IOSurface-backed) CGImage by drawing it into a
    /// malloc-backed bitmap context and snapshotting that — DOWNSCALED to the
    /// largest on-screen thumbnail size. The private CGSHWCaptureWindowList path
    /// returns windows at native resolution (often several MB each), which is
    /// what makes the cached bitmaps slow to fault/upload on a cold show and
    /// heavy enough that macOS compresses them. Downscaling to display size cuts
    /// each from ~MBs to ~100KB: cheap to decompress, small enough to keep
    /// resident, with no visible quality loss (never shown larger than this).
    static func detachedCopy(of cgImage: CGImage) -> CGImage? {
        let (width, height) = displaySize(cgImage.width, cgImage.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Target pixel size for a stored thumbnail: the full-resolution capture
    /// scaled to fit the largest on-screen thumbnail (points) at retina (2×),
    /// preserving aspect. Reads `TilesPanel.maxPossibleThumbnailSize` (set on
    /// main at layout; a stale read just yields a slightly different cap). Uses a
    /// fixed 2× rather than `NSScreen` since this runs off the main thread.
    private static func displaySize(_ srcW: Int, _ srcH: Int) -> (Int, Int) {
        guard srcW > 0, srcH > 0 else { return (0, 0) }
        // Cap at the on-screen thumbnail size (×2 for retina) AND an absolute
        // 512px long edge, so a handful of large windows can't bloat the cache.
        // 512×512×4 ≈ 1MB worst case per thumbnail; ~130 windows ≈ <150MB total.
        let maxNS = TilesPanel.maxPossibleThumbnailSize
        let maxW = min((maxNS.width > 1 ? maxNS.width : 256) * 2, 512)
        let maxH = min((maxNS.height > 1 ? maxNS.height : 256) * 2, 512)
        let ratio = min(1.0, maxW / CGFloat(srcW), maxH / CGFloat(srcH))
        return (max(1, Int((CGFloat(srcW) * ratio).rounded())), max(1, Int((CGFloat(srcH) * ratio).rounded())))
    }

    /// Detach an IOSurface-backed `CVPixelBuffer` (SCK output, 32BGRA) into a
    /// CGImage. `makeImage()` snapshots the locked bytes into an independent
    /// copy, so the pixel buffer (and its surface) can be released afterwards.
    static func detachedCopy(of pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }
        // downscale to display size so SCK thumbnails are also small
        return ctx.makeImage().flatMap { detachedCopy(of: $0) }
    }

    /// Keep the live surface for hot-tier (and all non-background) captures;
    /// detach warm/cold background captures. Safe to call from any thread.
    static func shouldDetach(_ source: RefreshCausedBy, wid: CGWindowID) -> Bool {
        // Always detach: every capture is immediately copied into a small,
        // display-sized, wired (mlock'd) bitmap and the WindowServer capture
        // IOSurface is released. This (a) means no live capture surfaces are ever
        // held → no WSIOSurfaceDebugTallyAndAbort risk, (b) keeps memory tiny
        // (~display-size × window-count instead of full-res), and (c) keeps the
        // bitmap resident so the first frame after idle composites it instantly.
        return true
    }
}
