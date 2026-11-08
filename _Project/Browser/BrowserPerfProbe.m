#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <sys/sysctl.h>

// Messsonde für Geräteläufe (nur DEBUG, nur mit Umgebungsvariable PERF_LOG=1):
// - „[Perf] Start“: Zeit vom Prozessbeginn bis zur ersten aktiven App (UIApplicationDidBecomeActive).
// - „[Perf] t=…“: alle 5 s Speicher (phys_footprint) und CPU-Anteil der App seit der letzten Zeile.
// WebContent-Prozesse sind eigene Prozesse und hier nicht enthalten.

#if DEBUG

static double BrowserPerfProcessStartTime(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0.0;
    }
    return (double)info.kp_proc.p_starttime.tv_sec + (double)info.kp_proc.p_starttime.tv_usec / 1e6;
}

static double BrowserPerfFootprintMB(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) != KERN_SUCCESS) {
        return 0.0;
    }
    return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
}

/// Summe der CPU-Zeit aller Threads der App in Sekunden.
static double BrowserPerfCPUSeconds(void) {
    struct task_thread_times_info times;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
    double total = 0.0;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&times, &count) == KERN_SUCCESS) {
        total += times.user_time.seconds + times.user_time.microseconds / 1e6;
        total += times.system_time.seconds + times.system_time.microseconds / 1e6;
    }
    struct task_basic_info basic;
    count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&basic, &count) == KERN_SUCCESS) {
        // Bereits beendete Threads.
        total += basic.user_time.seconds + basic.user_time.microseconds / 1e6;
        total += basic.system_time.seconds + basic.system_time.microseconds / 1e6;
    }
    return total;
}

@interface BrowserPerfProbe : NSObject
@end

@implementation BrowserPerfProbe

+ (void)load {
    if (![NSProcessInfo.processInfo.environment[@"PERF_LOG"] isEqualToString:@"1"]) {
        return;
    }
    __block id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                          object:nil
                                                                           queue:NSOperationQueue.mainQueue
                                                                      usingBlock:^(__unused NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        observer = nil;
        double start = BrowserPerfProcessStartTime();
        double now = NSDate.date.timeIntervalSince1970;
        NSLog(@"[Perf] Start bis aktiv %.0f ms, Speicher %.1f MB", (now - start) * 1000.0, BrowserPerfFootprintMB());
    }];

    static double lastCPU = 0.0;
    static double lastWall = 0.0;
    static double startWall = 0.0;
    startWall = NSDate.date.timeIntervalSince1970;
    lastWall = startWall;
    lastCPU = BrowserPerfCPUSeconds();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{
        double wall = NSDate.date.timeIntervalSince1970;
        double cpu = BrowserPerfCPUSeconds();
        double share = wall > lastWall ? (cpu - lastCPU) / (wall - lastWall) * 100.0 : 0.0;
        NSLog(@"[Perf] t=%.0fs Speicher %.1f MB CPU %.1f %%", wall - startWall, BrowserPerfFootprintMB(), share);
        lastWall = wall;
        lastCPU = cpu;
    });
    dispatch_resume(timer);
    static dispatch_source_t keep;
    keep = timer;
}

@end

#endif
