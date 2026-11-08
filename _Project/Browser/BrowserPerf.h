//
//  BrowserPerf.h
//  Browser
//
//  Leistungsmessung (nur DEBUG): Zeitstempel seit Prozessstart, Logpräfix [Perf].
//  Siehe docs/ERWEITERUNGEN.md, Abschnitte 14 und 15.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#if DEBUG
#import <sys/sysctl.h>
#import <sys/time.h>
#import <unistd.h>

/// Millisekunden seit dem Start des Prozesses (Startzeit aus dem Kernel, also inklusive dyld und main).
static inline double BrowserPerfMillisSinceProcessStart(void) {
    static double startMillis = 0;
    if (startMillis == 0) {
        struct kinfo_proc info;
        size_t size = sizeof(info);
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
        if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
            startMillis = info.kp_proc.p_starttime.tv_sec * 1000.0 + info.kp_proc.p_starttime.tv_usec / 1000.0;
        }
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    return startMillis > 0 ? now.tv_sec * 1000.0 + now.tv_usec / 1000.0 - startMillis : 0;
}

#define BrowserPerfLog(fmt, ...) NSLog(@"[Perf] " fmt @" (+%.0f ms seit Prozessstart)", ##__VA_ARGS__, BrowserPerfMillisSinceProcessStart())

/// Hauptthread-Wächter (nur mit Umgebungsvariable PERF_STALLS=1): Ein Zeitgeber auf der Hauptqueue tickt alle 10 ms;
/// kommt ein Tick mehr als 50 ms zu spät, war der Hauptthread so lange blockiert (Zeiger und Animationen stocken).
/// Loggt jede Blockade und alle 10 s die Summe.
static inline void BrowserPerfStartStallMonitorIfRequested(void) {
    if (![NSProcessInfo.processInfo.environment[@"PERF_STALLS"] isEqualToString:@"1"]) {
        return;
    }
    static dispatch_source_t timer;
    static CFTimeInterval last, windowStart, windowStall, windowMax;
    static NSUInteger windowCount;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    last = windowStart = CACurrentMediaTime();
    dispatch_source_set_event_handler(timer, ^{
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval gap = (now - last) * 1000.0 - 10.0;
        last = now;
        if (gap > 50.0) {
            windowStall += gap;
            windowCount += 1;
            windowMax = MAX(windowMax, gap);
            NSLog(@"[Perf] Hauptthread blockiert %.0f ms", gap);
        }
        if (now - windowStart >= 10.0) {
            NSLog(@"[Perf] Hauptthread 10 s: %lu Blockaden, zusammen %.0f ms, längste %.0f ms", (unsigned long)windowCount, windowStall, windowMax);
            windowStart = now;
            windowStall = 0;
            windowMax = 0;
            windowCount = 0;
        }
    });
    dispatch_resume(timer);
}
#else
#define BrowserPerfStartStallMonitorIfRequested() do { } while (0)
#define BrowserPerfLog(fmt, ...) do { } while (0)
#endif
