// Autonomous SDK installation recipe. This never loads a KataLog library.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <unistd.h>
#import <string.h>

static NSString *TestRoot;
static void Record(NSString *event, NSDictionary *values) {
    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:values ?: @{}];
    item[@"event"] = event; item[@"pid"] = @(getpid());
    NSData *json = [NSJSONSerialization dataWithJSONObject:item options:0 error:nil];
    NSString *path = [TestRoot stringByAppendingPathComponent:@"events.jsonl"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSData data] writeToFile:path atomically:YES];
    NSFileHandle *stream = [NSFileHandle fileHandleForWritingAtPath:path];
    [stream seekToEndOfFile]; [stream writeData:json]; [stream writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [stream closeFile];
}

@interface TestDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate, NSApplicationDelegate>
@property(strong) SPUUpdater *updater;
@end
@implementation TestDriver
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item { return NO; }
- (void)updaterWillRelaunchApplication:(SPUUpdater *)updater { Record(@"willRelaunch", nil); }
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { Record(@"checking", nil); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    Record(@"found", @{@"version": item.versionString}); reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { Record(@"releaseNotesError", @{@"code": @(error.code)}); }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack {
    Record(@"notFound", @{@"code": @(error.code)}); ack(); exit(2);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack {
    NSMutableArray *underlying = [NSMutableArray array];
    NSError *cause = error;
    for (NSUInteger depth = 0; cause && depth < 8; depth++) {
        [underlying addObject:@{@"domain": cause.domain, @"code": @(cause.code)}];
        cause = cause.userInfo[NSUnderlyingErrorKey];
    }
    Record(@"error", @{@"domain": error.domain, @"code": @(error.code), @"description": error.description, @"underlying": underlying}); ack(); exit(3);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { Record(@"download", nil); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { Record(@"downloadSize", @{@"length": @(length)}); }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { Record(@"extracting", nil); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { Record(@"ready", nil); reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry { Record(@"installing", @{@"terminated": @(terminated)}); }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { Record(@"installed", @{@"relaunched": @(relaunched)}); ack(); }
- (void)dismissUpdateInstallation {}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { Record(@"terminate", nil); return NSTerminateNow; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        TestRoot = [bundle objectForInfoDictionaryKey:@"KataLogUpdateTestRoot"];
        if (!TestRoot || ![TestRoot.lastPathComponent hasPrefix:@"katalog-update-install-"]) return 4;
        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        Record(@"startup", @{@"version": version, @"app": bundle.bundlePath});
        if (argc == 2 && strcmp(argv[1], "--verify-preserved-app") == 0) {
            if (![version isEqualToString:@"1"]) return 6;
            Record(@"preservedAppUsable", @{@"version": version}); return 0;
        }
        if ([version isEqualToString:@"2"]) { Record(@"relaunchVerified", nil); return 0; }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        TestDriver *driver = [TestDriver new]; app.delegate = driver;
        driver.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:driver delegate:driver];
        NSError *error = nil;
        if (![driver.updater startUpdater:&error]) { Record(@"startError", @{@"description": error.description}); return 5; }
        dispatch_async(dispatch_get_main_queue(), ^{ [driver.updater checkForUpdates]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Record(@"timeout", nil); exit(124); });
        [app run];
    }
    return 0;
}
