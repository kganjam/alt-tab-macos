// AltTab shim — TCC anchor binary.
//
// Goal: present a stable cdhash to the macOS TCC system across all rebuilds
// so that Accessibility / Screen Recording / Input Monitoring grants
// persist. The actual app code lives in Contents/Frameworks/AltTabCore.dylib
// and is replaced freely; this shim Mach-O is built ONCE and never modified.
//
// At launch:
//   1. Resolve our own path → walk up to .../Contents/Frameworks/AltTabCore.dylib
//   2. dlopen the dylib (RTLD_NOW so any missing symbols fail fast here, not later)
//   3. dlsym the C-callable entry point exported by the Swift dylib
//   4. Hand off argc/argv and return its exit status
//
// All Cocoa/AppKit setup (NSApp init, run loop, etc.) happens inside the
// dylib's alt_tab_main — by the time it returns, the app has shut down.
//
// Library validation must be disabled via entitlement on this binary; the
// dylib is signed with the same self-signed cert (no Team ID) and would
// otherwise be rejected under hardened runtime.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syslimits.h>

typedef int (*entry_t)(int argc, char** argv);

static int strip_path_component(char* p) {
    char* slash = strrchr(p, '/');
    if (!slash) return -1;
    *slash = 0;
    return 0;
}

int main(int argc, char** argv) {
    char dylib[PATH_MAX];
    // Dev override: when set, load AltTabCore.dylib from a path outside
    // the bundle. Lets us iterate the dylib without touching the installed
    // bundle, which would break the code-signing seal and revoke TCC. The
    // installed bundle is what holds the TCC grant (Accessibility, Screen
    // Recording etc.); leaving it sealed means grants persist across
    // dev rebuilds.
    const char* override = getenv("ALTTAB_DYLIB_OVERRIDE");
    if (override && override[0] != '\0') {
        int n = snprintf(dylib, sizeof(dylib), "%s", override);
        if (n < 0 || (size_t)n >= sizeof(dylib)) {
            fprintf(stderr, "AltTab shim: ALTTAB_DYLIB_OVERRIDE path too long\n");
            return 1;
        }
        fprintf(stderr, "AltTab shim: dev mode — loading dylib from override: %s\n", dylib);
    } else {
        char exe[PATH_MAX];
        uint32_t size = sizeof(exe);
        if (_NSGetExecutablePath(exe, &size) != 0) {
            fprintf(stderr, "AltTab shim: _NSGetExecutablePath failed (need bigger buffer?)\n");
            return 1;
        }
        // exe is .../Contents/MacOS/AltTab — strip "AltTab" then "MacOS" → .../Contents
        if (strip_path_component(exe) != 0 || strip_path_component(exe) != 0) {
            fprintf(stderr, "AltTab shim: cannot derive Contents/ from %s\n", exe);
            return 1;
        }
        int n = snprintf(dylib, sizeof(dylib), "%s/Frameworks/AltTabCore.dylib", exe);
        if (n < 0 || (size_t)n >= sizeof(dylib)) {
            fprintf(stderr, "AltTab shim: dylib path too long\n");
            return 1;
        }
    }
    void* handle = dlopen(dylib, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        fprintf(stderr, "AltTab shim: dlopen(%s) failed: %s\n", dylib, dlerror());
        return 1;
    }
    entry_t entry = (entry_t)dlsym(handle, "alt_tab_main");
    if (!entry) {
        fprintf(stderr, "AltTab shim: dlsym(alt_tab_main) failed: %s\n", dlerror());
        return 1;
    }
    return entry(argc, argv);
}
