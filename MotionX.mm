// MotionX 2.2 semantic reconstruction from supplied binary; names are reconstructed.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <pthread.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <stdint.h>
extern "C" void MSHookMessageEx(Class, SEL, IMP, IMP *);
extern "C" const char *getprogname(void);

// 0x6968
static bool MotionXProcess(const char *name) {
    const char *p = getprogname(); return p && name && strcmp(p, name) == 0;
}
// 0x6a08 and 0x6f28
static void MotionXHook(const char *name, SEL s, IMP replacement, IMP *original, bool meta = false) {
    Class c = objc_getClass(name);
    if (!c) return;
    if (meta) {
        if (!class_getClassMethod(c, s)) return;
        c = object_getClass(c);
    } else if (!class_getInstanceMethod(c, s)) return;
    MSHookMessageEx(c, s, replacement, original);
}
// 0x7590: runtime lookup, rather than respondsToSelector:, is intentional.
static bool MotionXHas(id obj, SEL s) {
    if (!obj || !s) return false;
    Class c = object_getClass(obj);
    return c && class_getInstanceMethod(c, s);
}
static pthread_once_t MotionXOnce = PTHREAD_ONCE_INIT;
static pthread_key_t MotionXCaptureKey, MotionXWriterKey;
// 0x71bc; original ignores pthread error returns, keys have no destructors.
static void MotionXKeys(void) {
    pthread_key_create(&MotionXCaptureKey, NULL);
    pthread_key_create(&MotionXWriterKey, NULL);
}
static void MotionXEnsureKeys(void) { pthread_once(&MotionXOnce, MotionXKeys); }
static void (*MotionXOrigSession)(id, SEL, int, CGSize, BOOL, id, id, id);
// 0x6a74. Blocks are forwarded opaquely; there are no block invoke bodies in this dylib.
static void MotionXSession(id obj, SEL cmd, int pid, CGSize size, BOOL system, id contexts, id output, id started) {
    uintptr_t active = MotionXProcess("replayd") & (unsigned)system;
    MotionXEnsureKeys();
    void *saved = pthread_getspecific(MotionXCaptureKey);
    pthread_setspecific(MotionXCaptureKey, (void *)active);
    @try {
        if (MotionXOrigSession) MotionXOrigSession(obj, cmd, pid, size, system, contexts, output, started);
    } @finally { pthread_setspecific(MotionXCaptureKey, saved); }
}
static void (*MotionXOrigWriter)(id, SEL, id);
// 0x6bc8
static void MotionXWriter(id obj, SEL cmd, id handler) {
    uintptr_t active = 0;
    SEL s = sel_registerName("systemRecording");
    if (MotionXProcess("replayd") && MotionXHas(obj, s))
        active = ((BOOL (*)(id, SEL))objc_msgSend)(obj, s);
    MotionXEnsureKeys();
    void *saved = pthread_getspecific(MotionXWriterKey);
    pthread_setspecific(MotionXWriterKey, (void *)active);
    @try { if (MotionXOrigWriter) MotionXOrigWriter(obj, cmd, handler); }
    @finally { pthread_setspecific(MotionXWriterKey, saved); }
}
static id (*MotionXOrigInput)(id, SEL, id, id);
// 0x6d20. Manual retain/release matches the original's non-ARC ownership.
static id MotionXInput(id obj, SEL cmd, id mediaType, id settings) {
    if (MotionXProcess("replayd")) {
        MotionXEnsureKeys();
        if (pthread_getspecific(MotionXWriterKey) && [mediaType isEqualToString:AVMediaTypeVideo] && settings) {
            NSMutableDictionary *copy = [settings mutableCopy];
            if (copy) {
                id old = [copy objectForKey:AVVideoCompressionPropertiesKey];
                NSMutableDictionary *compression = [old isKindOfClass:[NSDictionary class]] ?
                    [old mutableCopy] : [[NSMutableDictionary alloc] init];
                [compression setObject:[NSNumber numberWithInt:120] forKey:AVVideoExpectedSourceFrameRateKey];
                [compression setObject:[NSNumber numberWithInt:120] forKey:AVVideoMaxKeyFrameIntervalKey];
                [copy setObject:compression forKey:AVVideoCompressionPropertiesKey];
                [compression release];
                settings = [copy autorelease];
            }
        }
    }
    return MotionXOrigInput ? MotionXOrigInput(obj, cmd, mediaType, settings) : nil;
}
static id (*MotionXOrigCapture)(id, SEL, CGSize, CMTime);
// 0x6f9c. CMTime is passed by value (indirect in the arm64 ABI).
static id MotionXCapture(id obj, SEL cmd, CGSize size, CMTime interval) {
    bool changed = false;
    if (MotionXProcess("replayd")) {
        MotionXEnsureKeys();
        if (pthread_getspecific(MotionXCaptureKey) &&
            (interval.flags & 0x1d) == 1 && interval.value >= 1 && interval.timescale >= 1) {
            double seconds = CMTimeGetSeconds(interval);
            if (isfinite(seconds) && seconds > 0.015 && seconds < 0.0185) {
                interval = CMTimeMake(1, 120); changed = true;
            }
        }
    }
    id result = MotionXOrigCapture ? MotionXOrigCapture(obj, cmd, size, interval) : nil;
    if (changed && result) {
        @try {
            SEL s = sel_registerName("setFigVirtualDisplayOption:forKey:");
            if ([result respondsToSelector:s]) {
                CFStringRef *symbol = (CFStringRef *)dlsym(RTLD_DEFAULT, "kFigVirtualDisplaySinkOption_VSyncRate");
                if (symbol && *symbol)
                    ((void (*)(id, SEL, id, id))objc_msgSend)(result, s, [NSNumber numberWithInt:120], (id)*symbol);
            }
        } @catch (NSException *exception) { (void)exception; }
    }
    return result;
}

// 0x71fc
static bool MotionXSystemProcess(void) {
    return MotionXProcess("SpringBoard") || MotionXProcess("replayd") || MotionXProcess("backboardd");
}
static void (*MotionXOrigReasons)(id, SEL, const int *, NSUInteger);
// 0x7248
static void MotionXReasons(id obj, SEL cmd, const int *reasons, NSUInteger count) {
    int one = 1;
    bool system = MotionXSystemProcess();
    if (MotionXOrigReasons) MotionXOrigReasons(obj, cmd, system ? &one : reasons, system ? 1 : count);
}
// 0x72b8
static NSInteger MotionXMaximumFPS(id obj, SEL cmd) { return 120; }
static void (*MotionXOrigFPS)(id, SEL, NSInteger);
static void (*MotionXOrigInterval)(id, SEL, NSInteger);
static void (*MotionXOrigLinkRange)(id, SEL, CAFrameRateRange);
static void (*MotionXOrigAnimationRange)(id, SEL, CAFrameRateRange);
static void (*MotionXOrigSourceRange)(id, SEL, CAFrameRateRange);
// 0x72c0, 0x72d8
static void MotionXFPS(id obj, SEL cmd, NSInteger value) {
    if (MotionXOrigFPS) MotionXOrigFPS(obj, cmd, 120);
}
static void MotionXInterval(id obj, SEL cmd, NSInteger value) {
    if (MotionXOrigInterval) MotionXOrigInterval(obj, cmd, 1);
}
// 0x72f0, 0x7314, 0x7338
static CAFrameRateRange MotionXRange(void) { return (CAFrameRateRange){120, 120, 120}; }
static void MotionXLinkRange(id obj, SEL cmd, CAFrameRateRange range) {
    if (MotionXOrigLinkRange) MotionXOrigLinkRange(obj, cmd, MotionXRange());
}
static void MotionXAnimationRange(id obj, SEL cmd, CAFrameRateRange range) {
    if (MotionXOrigAnimationRange) MotionXOrigAnimationRange(obj, cmd, MotionXRange());
}
static void MotionXSourceRange(id obj, SEL cmd, CAFrameRateRange range) {
    if (MotionXOrigSourceRange) MotionXOrigSourceRange(obj, cmd, MotionXRange());
}
// 0x74b0
static void MotionXBoost(id obj) {
    if (!obj) return;
    SEL single = sel_registerName("setHighFrameRateReason:");
    SEL multiple = sel_registerName("setHighFrameRateReasons:count:");
    SEL range = sel_registerName("setPreferredFrameRateRange:");
    int one = 1;
    if (MotionXHas(obj, single)) ((void (*)(id, SEL, int))objc_msgSend)(obj, single, 1);
    if (MotionXHas(obj, multiple)) ((void (*)(id, SEL, const int *, NSUInteger))objc_msgSend)(obj, multiple, &one, 1);
    if (MotionXHas(obj, range)) ((void (*)(id, SEL, CAFrameRateRange))objc_msgSend)(obj, range, MotionXRange());
}
static double MotionXLastBoost;
static id MotionXSource;
// 0x75dc: retains init result for process lifetime, retries missing classes on later calls.
static void MotionXBoostSpringBoard(void) {
    if (!MotionXProcess("SpringBoard") || !pthread_main_np()) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (MotionXLastBoost > 0 && now - MotionXLastBoost < 0.2) return;
    if (!MotionXSource) {
        Class displayClass = objc_getClass("CADisplay");
        Class sourceClass = objc_getClass("CADynamicFrameRateSource");
        SEL mainDisplay = sel_registerName("mainDisplay");
        SEL initializer = sel_registerName("initWithDisplay:");
        if (!displayClass || !sourceClass || !class_getClassMethod(displayClass, mainDisplay) ||
            !class_getInstanceMethod(sourceClass, initializer)) { MotionXSource = nil; return; }
        id display = ((id (*)(id, SEL))objc_msgSend)((id)displayClass, mainDisplay);
        if (!display) { MotionXSource = nil; return; }
        id allocated = ((id (*)(id, SEL))objc_msgSend)((id)sourceClass, sel_registerName("alloc"));
        if (!allocated) { MotionXSource = nil; return; }
        MotionXSource = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initializer, display);
        if (!MotionXSource) return;
    }
    MotionXLastBoost = now;
    MotionXBoost(MotionXSource);
}
static id (*MotionXOrigDisplayLink)(id, SEL, id, SEL);
// 0x735c
static id MotionXDisplayLink(id obj, SEL cmd, id target, SEL action) {
    id link = MotionXOrigDisplayLink ? MotionXOrigDisplayLink(obj, cmd, target, action) : nil;
    if (link) MotionXBoost(link);
    return link;
}
static void (*MotionXOrigOffset)(id, SEL, CGPoint);
static void (*MotionXOrigAnimatedOffset)(id, SEL, CGPoint, BOOL);
static void (*MotionXOrigMoved)(id, SEL);
// 0x73a4, 0x740c, 0x7488
static void MotionXOffset(id obj, SEL cmd, CGPoint point) {
    MotionXBoostSpringBoard(); if (MotionXOrigOffset) MotionXOrigOffset(obj, cmd, point);
}
static void MotionXAnimatedOffset(id obj, SEL cmd, CGPoint point, BOOL animated) {
    MotionXBoostSpringBoard(); if (MotionXOrigAnimatedOffset) MotionXOrigAnimatedOffset(obj, cmd, point, animated);
}
static void MotionXMoved(id obj, SEL cmd) {
    if (MotionXOrigMoved) MotionXOrigMoved(obj, cmd); MotionXBoostSpringBoard();
}
// 0x7734..0x776c: separate originals are kept even though constant hooks never call them.
static NSInteger MotionXPolicyMaximum(id obj, SEL cmd) { return 120; }
static double MotionXEffectiveMaximum(id obj, SEL cmd) { return 120.0; }
static double MotionXPolicyRate(id obj, SEL cmd) { return 120.0; }
static BOOL MotionXLimitEnabled(id obj, SEL cmd) { return NO; }
static BOOL MotionXShouldLimit(id obj, SEL cmd) { return NO; }
static NSInteger MotionXControllerMaximum(id obj, SEL cmd) { return 120; }
static IMP MotionXUnusedOriginals[7];
// 0x69b0
static void MotionXInstallReasons(void) {
    if (MotionXSystemProcess()) MotionXHook("CADynamicFrameRateSource", sel_registerName("setHighFrameRateReasons:count:"),
                                         (IMP)MotionXReasons, (IMP *)&MotionXOrigReasons);
}
#define MOTIONX_HOOK(cls, sel, fn, orig) MotionXHook(cls, sel_registerName(sel), (IMP)fn, (IMP *)&orig)
// 0x64fc; constructor order and early returns mirror the binary.
__attribute__((constructor)) static void MotionXInitialize(void) {
    if (MotionXProcess("replayd")) {
        if (!MotionXProcess("replayd")) return;
        MotionXEnsureKeys();
        dlopen("/System/Library/Frameworks/ReplayKit.framework/ReplayKit", 5);
        dlopen("/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox", 5);
        SEL session = sel_registerName("startSessionWithPID:windowSize:systemRecording:contextIDs:outputHandler:didStartHandler:");
        Class manager = objc_getClass("RPScreenCaptureManagerIOS");
        Method method = manager ? class_getInstanceMethod(manager, session) : NULL;
        if (method && method_getNumberOfArguments(method) == 8)
            MotionXHook("RPScreenCaptureManagerIOS", session, (IMP)MotionXSession, (IMP *)&MotionXOrigSession);
        MOTIONX_HOOK("RPMovieWriter", "setUpAssetWriterWithHandler:", MotionXWriter, MotionXOrigWriter);
        MOTIONX_HOOK("AVAssetWriterInput", "initWithMediaType:outputSettings:", MotionXInput, MotionXOrigInput);
        MotionXHook("FigScreenCaptureController", sel_registerName("screenCaptureControllerWithSize:minIntervalBetweenFrames:"),
                    (IMP)MotionXCapture, (IMP *)&MotionXOrigCapture, true);
        return;
    }
    if (MotionXProcess("backboardd")) { MotionXInstallReasons(); return; }
    MOTIONX_HOOK("UIScreen", "maximumFramesPerSecond", MotionXMaximumFPS, MotionXUnusedOriginals[0]);
    MOTIONX_HOOK("CADisplayLink", "setPreferredFramesPerSecond:", MotionXFPS, MotionXOrigFPS);
    MOTIONX_HOOK("CADisplayLink", "setFrameInterval:", MotionXInterval, MotionXOrigInterval);
    MOTIONX_HOOK("CADisplayLink", "setPreferredFrameRateRange:", MotionXLinkRange, MotionXOrigLinkRange);
    MOTIONX_HOOK("CAAnimation", "setPreferredFrameRateRange:", MotionXAnimationRange, MotionXOrigAnimationRange);
    MOTIONX_HOOK("CADynamicFrameRateSource", "setPreferredFrameRateRange:", MotionXSourceRange, MotionXOrigSourceRange);
    MotionXInstallReasons();
    if (MotionXProcess("SpringBoard")) {
        MotionXHook("CADisplayLink", sel_registerName("displayLinkWithTarget:selector:"), (IMP)MotionXDisplayLink,
                    (IMP *)&MotionXOrigDisplayLink, true);
        MOTIONX_HOOK("UIScrollView", "setContentOffset:", MotionXOffset, MotionXOrigOffset);
        MOTIONX_HOOK("UIScrollView", "setContentOffset:animated:", MotionXAnimatedOffset, MotionXOrigAnimatedOffset);
        MOTIONX_HOOK("NCNotificationShortLookView", "didMoveToWindow", MotionXMoved, MotionXOrigMoved);
    }
    MOTIONX_HOOK("SBProMotionPolicy", "maximumSupportedRefreshRate", MotionXPolicyMaximum, MotionXUnusedOriginals[1]);
    MOTIONX_HOOK("SBProMotionPolicy", "effectiveMaxRefreshRate", MotionXEffectiveMaximum, MotionXUnusedOriginals[2]);
    MOTIONX_HOOK("SBProMotionPolicy", "policyRefreshRate", MotionXPolicyRate, MotionXUnusedOriginals[3]);
    MOTIONX_HOOK("SBProMotionPolicy", "isLimitFrameRateEnabled", MotionXLimitEnabled, MotionXUnusedOriginals[4]);
    MOTIONX_HOOK("SBProMotionPolicy", "shouldLimitFrameRate", MotionXShouldLimit, MotionXUnusedOriginals[5]);
    MOTIONX_HOOK("SBDisplayRefreshRateController", "maximumRefreshRate", MotionXControllerMaximum, MotionXUnusedOriginals[6]);
}
