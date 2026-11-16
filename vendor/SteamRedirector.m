#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Passed in by the Xcode build phase from PRODUCT_BUNDLE_IDENTIFIER, so the
// Launch Services fallback below can't drift from the app's real ID.
#ifndef LAUNCHER_BUNDLE_ID
#define LAUNCHER_BUNDLE_ID "com.matthjs.bo3launcher"
#endif

// Opens the launcher with bo3launcher://steam-play, so it knows Steam's Play
// button sent it and can start the game straight away if the player chose
// that. The URL goes to this particular copy of the app, not whichever copy
// Launch Services would pick for the scheme. Falls back to just opening the
// app if that fails.
static BOOL openLauncher(NSURL *appURL) {
    NSURL *playURL = [NSURL URLWithString:@"bo3launcher://steam-play"];
    __block BOOL opened = NO;
    if (@available(macOS 10.15, *)) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace] openURLs:@[playURL]
                           withApplicationAtURL:appURL
                                  configuration:config
                              completionHandler:^(NSRunningApplication *app, NSError *error) {
            opened = (error == nil);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    }
    return opened || [[NSWorkspace sharedWorkspace] openURL:appURL];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Look for BO3 Launcher.app in known locations
        NSArray *searchPaths = @[
            @"/Applications/BO3 Launcher.app",
            [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/BO3 Launcher.app"],
            // Also check next to the game itself (in the BO3MacFix folder)
            [[[NSString stringWithUTF8String:argv[0]]
                stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"../../../BO3MacFix/BO3 Launcher.app"],
        ];

        for (NSString *path in searchPaths) {
            NSString *resolved = [path stringByStandardizingPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:resolved]) {
                openLauncher([NSURL fileURLWithPath:resolved]);
                return 0;
            }
        }

        // Fallback: try to find it via Launch Services
        NSArray *urls = [[NSWorkspace sharedWorkspace]
            URLsForApplicationsWithBundleIdentifier:@LAUNCHER_BUNDLE_ID];
        if (urls.count > 0) {
            openLauncher(urls[0]);
            return 0;
        }

        // Last resort: show error
        NSLog(@"BO3 Launcher.app not found. Install it to /Applications.");
        return 1;
    }
}
