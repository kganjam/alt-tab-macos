import AppKit
import Darwin

/// Entry point called by the shim binary at Contents/MacOS/AltTab. The shim
/// dlopens this dylib and calls alt_tab_main with the host process's argc/argv.
/// Returns when App.shared.run() returns (i.e. when AltTab exits its run loop)
/// or via emergencyExit() which calls exit() directly.
@_cdecl("alt_tab_main")
public func altTabMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    if let command = CliClient.detectCommand() {
        CliClient.sendCommandAndProcessResponse(command)
    }
    // - SIGTERM: if the app is quit/force-quit from Activity Monitor, it will receive SIGTERM and applicationWillTerminate won't be called
    // - SIGTRAP: if the app crashes in swift code (e.g. unexpected nil object), SIGTRAP is sent
    // - SIGKILL: if we stop the app using SIGKILL (e.g. stopping from IntelliJ, or from the terminal), there is no chance to intercept it
    [SIGTERM, SIGTRAP].forEach {
        signal($0) { s in
            emergencyExit("Exiting after receiving signal", s)
        }
    }
    // - if the app crashes in objective-c code, an NSException may be sent
    // we intercept the exception, and do an emergency exit
    NSSetUncaughtExceptionHandler { (exception) in
        emergencyExit("Exiting after receiving uncaught NSException", exception)
    }
    App.shared.run()
    return 0
}

func printStackTrace() {
    let stackSymbols = Thread.callStackSymbols
    for symbol in stackSymbols {
        print(symbol)
    }
}

// during an emergency exit, we re-enable the native command+tab, and log.
// We DO NOT call Winside.stop() here: this function runs from a signal
// handler context (SIGTERM / SIGTRAP), where queue.sync, Process spawn,
// and file I/O are not async-signal-safe and crash the process. Helper
// cleanup for these cases is covered externally:
//   - bash ai/build.sh runs a defensive kill via prlctl exec before
//     launching the new AltTab.
//   - The next AltTab launch's startIfNeeded detects an orphan
//     (status file present) and kills it before launching a fresh
//     helper.
fileprivate func emergencyExit(_ logs: Any?...) {
    setNativeCommandTabEnabled(true)
    print(logs)
    printStackTrace()
    makeSureAllCapturesAreFinished()
    exit(0)
}

func makeSureAllCapturesAreFinished() {
    App.isTerminating = true
    let timeout = 5.0
    let startTime = DispatchTime.now()
    var elapsedTime = 0.0
    while ActiveWindowCaptures.value() > 0 && elapsedTime <= timeout {
        Logger.warning { "There are \(ActiveWindowCaptures.value()) screenshots in progress. We need to wait for them to avoid a bug where macOS shows permission dialogs to the user for no reason." }
        Thread.sleep(forTimeInterval: 0.1)
        elapsedTime = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
    }
}
