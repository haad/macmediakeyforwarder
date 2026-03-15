#import "AppDelegate.h"
#import "GBLaunchAtLogin.h"
#import "iTunes.h"
#import "Spotify.h"
#import "Endel.h"
#import <CoreServices/CoreServices.h>
#import <ScriptingBridge/ScriptingBridge.h>

typedef NS_ENUM(NSInteger, AppType)
{
    AppTypeSpotify,
    AppTypeMusic,
    AppTypeEndel,
};

typedef NS_ENUM(NSInteger, SecondaryApp)
{
    SecondaryAppSpotify,   // Use Spotify as secondary (default)
    SecondaryAppMusic,     // Use Apple Music as secondary
};

typedef NS_ENUM(NSInteger, PauseState)
{
    // pause app
    PauseStateNone,
    // pause app
    PauseStatePause,
    // pause app automatically when iTunes and Spotify is not running
    PauseStateAutomatic,
};

typedef NS_ENUM(NSInteger, KeyHoldState)
{
    KeyHoldStateNone,
    KeyHoldStateWaiting,
    KeyHoldStateHolding
};

static NSString *kUserDefaultsPriorityOptionKey = @"user_priority_option";
static NSString *kUserDefaultsPauseOptionKey = @"user_pause_option";
static NSString *kUserDefaultsHideFromMenuBarOptionKey = @"user_hide_from_menu_bar_option";

PauseState pauseState;
KeyHoldState keyHoldStatus;
SecondaryApp secondaryApp;

@interface AppDelegate ()
{
    NSStatusItem* statusItem;
    CFMachPortRef eventPort;
    CFRunLoopSourceRef eventPortSource;
    NSMutableArray *priorityOptionItems;
    NSMutableArray *pauseOptionItems;
    NSMenuItem *startupItem;
    NSMenuItem *hideFromMenuBarItem;
}

@end

@implementation AppDelegate

static void sendKeyToApp(SBApplication *app, AppType appType, int keyCode)
{
    switch (appType)
    {
        case AppTypeSpotify:
        {
            SpotifyApplication *spotify = (SpotifyApplication *)app;
            switch (keyCode)
            {
                case NX_KEYTYPE_PLAY:
                    [spotify playpause];
                    break;
                case NX_KEYTYPE_NEXT:
                case NX_KEYTYPE_FAST:
                    [spotify nextTrack];
                    break;
                case NX_KEYTYPE_PREVIOUS:
                case NX_KEYTYPE_REWIND:
                    [spotify previousTrack];
                    break;
            }
            break;
        }
        case AppTypeMusic:
        {
            iTunesApplication *music = (iTunesApplication *)app;
            switch (keyCode)
            {
                case NX_KEYTYPE_PLAY:
                    [music playpause];
                    break;
                case NX_KEYTYPE_NEXT:
                case NX_KEYTYPE_FAST:
                    [music nextTrack];
                    break;
                case NX_KEYTYPE_PREVIOUS:
                case NX_KEYTYPE_REWIND:
                    [music backTrack];
                    break;
            }
            break;
        }
        case AppTypeEndel:
        {
            EndelApplication *endel = (EndelApplication *)app;
            switch (keyCode)
            {
                case NX_KEYTYPE_PLAY:
                    [endel playpause];
                    break;
                case NX_KEYTYPE_NEXT:
                case NX_KEYTYPE_FAST:
                    [endel nextTrack];
                    break;
                case NX_KEYTYPE_PREVIOUS:
                case NX_KEYTYPE_REWIND:
                    [endel previousTrack];
                    break;
            }
            break;
        }
    }
}

static BOOL isAppPlaying(SBApplication *app, AppType appType)
{
    if (![app isRunning]) return NO;

    switch (appType)
    {
        case AppTypeSpotify:
            return ((SpotifyApplication *)app).playerState == SpotifyEPlSPlaying;
        case AppTypeMusic:
            return ((iTunesApplication *)app).playerState == iTunesEPlSPlaying;
        case AppTypeEndel:
            return ((EndelApplication *)app).playerState == EndelEPlSPlaying;
    }
    return NO;
}

static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    @autoreleasepool
    {
        AppDelegate *self = (__bridge id)refcon;

        if(type == kCGEventTapDisabledByTimeout)
        {
            CGEventTapEnable(self->eventPort, TRUE);
            return event;
        }

        if(type == kCGEventTapDisabledByUserInput)
        {
            return event;
        }

        if(type != NX_SYSDEFINED )
        {
            return event;
        }

        NSEvent *nsEvent = nil;
        @try
        {
            nsEvent = [NSEvent eventWithCGEvent:event];
        }
        @catch (NSException * e)
        {
            return event;
        }

        if([nsEvent subtype] != 8)
        {
            return event;
        }

        int keyCode = (([nsEvent data1] & 0xFFFF0000) >> 16);

        if (keyCode != NX_KEYTYPE_PLAY &&
            keyCode != NX_KEYTYPE_FAST &&
            keyCode != NX_KEYTYPE_REWIND &&
            keyCode != NX_KEYTYPE_PREVIOUS &&
            keyCode != NX_KEYTYPE_NEXT)
        {
            return event;
        }

        SBApplication *spotify = [SBApplication applicationWithBundleIdentifier:@"com.spotify.client"];
        SBApplication *music = [SBApplication applicationWithBundleIdentifier:@"com.apple.music"];
        SBApplication *endel = [SBApplication applicationWithBundleIdentifier:@"com.endel.endel"];

        if ( pauseState == PauseStatePause )
        {
            return event;
        }

        if ( pauseState == PauseStateAutomatic )
        {
            if (![spotify isRunning] && ![music isRunning] && ![endel isRunning])
            {
                return event;
            }
        }

        int keyFlags = ([nsEvent data1] & 0x0000FFFF);
        BOOL keyIsPressed = (((keyFlags & 0xFF00) >> 8)) == 0xA;

        if (keyIsPressed)
        {
            // Build arrays of playing and running apps (with parallel type tracking)
            NSMutableArray *playingApps = [NSMutableArray array];
            NSMutableArray *playingTypes = [NSMutableArray array];
            NSMutableArray *runningApps = [NSMutableArray array];
            NSMutableArray *runningTypes = [NSMutableArray array];

            if ([endel isRunning])
            {
                [runningApps addObject:endel];
                [runningTypes addObject:@(AppTypeEndel)];
                if (isAppPlaying(endel, AppTypeEndel))
                {
                    [playingApps addObject:endel];
                    [playingTypes addObject:@(AppTypeEndel)];
                }
            }

            // Determine which is the configured secondary app
            SBApplication *secondaryAppInstance = nil;
            AppType secondaryAppType;
            if (secondaryApp == SecondaryAppSpotify)
            {
                secondaryAppInstance = spotify;
                secondaryAppType = AppTypeSpotify;
            }
            else
            {
                secondaryAppInstance = music;
                secondaryAppType = AppTypeMusic;
            }

            // Also check the non-configured one for playing state
            SBApplication *otherAppInstance = nil;
            AppType otherAppType;
            if (secondaryApp == SecondaryAppSpotify)
            {
                otherAppInstance = music;
                otherAppType = AppTypeMusic;
            }
            else
            {
                otherAppInstance = spotify;
                otherAppType = AppTypeSpotify;
            }

            if ([secondaryAppInstance isRunning])
            {
                [runningApps addObject:secondaryAppInstance];
                [runningTypes addObject:@(secondaryAppType)];
                if (isAppPlaying(secondaryAppInstance, secondaryAppType))
                {
                    [playingApps addObject:secondaryAppInstance];
                    [playingTypes addObject:@(secondaryAppType)];
                }
            }
            if ([otherAppInstance isRunning])
            {
                [runningApps addObject:otherAppInstance];
                [runningTypes addObject:@(otherAppType)];
                if (isAppPlaying(otherAppInstance, otherAppType))
                {
                    [playingApps addObject:otherAppInstance];
                    [playingTypes addObject:@(otherAppType)];
                }
            }

            if ([playingApps count] > 0)
            {
                // Send to all playing apps
                for (NSUInteger i = 0; i < [playingApps count]; i++)
                {
                    sendKeyToApp(playingApps[i], (AppType)[playingTypes[i] integerValue], keyCode);
                }
            }
            else if ([runningApps count] > 0)
            {
                // Send to running apps in priority order: Endel > secondary
                // Just send to the first running app (Endel is added first)
                sendKeyToApp(runningApps[0], (AppType)[runningTypes[0] integerValue], keyCode);
            }
            else
            {
                // No app running - launch the configured secondary app (never Endel)
                sendKeyToApp(secondaryAppInstance, secondaryAppType, keyCode);
            }
        }

        // stop propagation

        return NULL;
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{

}

- ( void ) applicationDidFinishLaunching : ( NSNotification*) theNotification
{
    // init containers

    priorityOptionItems = [[NSMutableArray alloc] init];
    pauseOptionItems = [[NSMutableArray alloc] init];

    // init states

    pauseState = PauseStateNone;
    keyHoldStatus = KeyHoldStateNone;
    secondaryApp = SecondaryAppSpotify;

    NSNumber *option = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsPriorityOptionKey];
    if ( option )
    {
        secondaryApp = [option integerValue];
    }

    option = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsPauseOptionKey];
    if ( option )
    {
        pauseState = [option integerValue];
    }

    // Version string

    NSDictionary *bundleInfo = [[NSBundle mainBundle] infoDictionary];
    NSString *versionString = [NSString stringWithFormat:@"Version %@ (build %@)",
                               bundleInfo[@"CFBundleShortVersionString"],
                               bundleInfo[@"CFBundleVersion"] ];

    NSMenu *menu = [ [ NSMenu alloc ] init ];
    [ menu setDelegate : self ];
    NSMenuItem *versionItem = [ menu addItemWithTitle : versionString action : nil keyEquivalent : @"" ];
    versionItem.image = [self menuImageWithSymbol:@"info.circle"];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem *pauseItem = [ menu addItemWithTitle: NSLocalizedString(@"Pause", @"Pause") action : @selector(manualPause) keyEquivalent : @"" ];
    pauseItem.image = [self menuImageWithSymbol:@"pause.circle"];
    [pauseOptionItems addObject:pauseItem];
    NSMenuItem *autoPauseItem = [ menu addItemWithTitle: NSLocalizedString(@"Pause if no player is running", @"Pause if no player is running") action : @selector(autoPause) keyEquivalent : @"" ];
    autoPauseItem.image = [self menuImageWithSymbol:@"pause.circle.fill"];
    [pauseOptionItems addObject:autoPauseItem];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem *spotifyItem = [ menu addItemWithTitle: NSLocalizedString(@"Use Spotify as secondary player", @"Use Spotify as secondary player") action : @selector(selectSpotifySecondary) keyEquivalent : @"" ];
    spotifyItem.image = [self menuImageWithSymbol:@"music.note"];
    [priorityOptionItems addObject:spotifyItem];
    NSMenuItem *musicItem = [ menu addItemWithTitle: NSLocalizedString(@"Use Apple Music as secondary player", @"Use Apple Music as secondary player") action : @selector(selectMusicSecondary) keyEquivalent : @"" ];
    musicItem.image = [self menuImageWithSymbol:@"music.quarternote.3"];
    [priorityOptionItems addObject:musicItem];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    startupItem = [ menu addItemWithTitle:NSLocalizedString(@"Open at login", @"Open at login") action:@selector(toggleStartupItem) keyEquivalent:@""];
    startupItem.image = [self menuImageWithSymbol:@"arrow.right.circle"];
    hideFromMenuBarItem = [ menu addItemWithTitle:NSLocalizedString(@"Hide from menu bar", @"Hide from menu bar") action:@selector(hideFromMenuBar) keyEquivalent:@""];
    hideFromMenuBarItem.image = [self menuImageWithSymbol:@"eye.slash"];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem *donateItem = [ menu addItemWithTitle : NSLocalizedString(@"Donate if you like the app", @"Donate if you like the app") action : @selector(support) keyEquivalent : @"" ];
    donateItem.image = [self menuImageWithSymbol:@"heart"];
    NSMenuItem *updateItem = [ menu addItemWithTitle : NSLocalizedString(@"Check for updates", @"Check for updates") action : @selector(update) keyEquivalent : @"" ];
    updateItem.image = [self menuImageWithSymbol:@"arrow.triangle.2.circlepath"];
    NSMenuItem *quitItem = [ menu addItemWithTitle : NSLocalizedString(@"Quit", @"Quit") action : @selector(terminate) keyEquivalent : @"" ];
    quitItem.image = [self menuImageWithSymbol:@"xmark.circle"];

    NSImage *image = [NSImage imageWithSystemSymbolName:@"forward.fill" accessibilityDescription:@"Mac Media Key Forwarder"];

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];
    statusItem.button.image = image;
    statusItem.button.toolTip = @"Mac Media Key Forwarder";
    statusItem.menu = menu;
    [ statusItem setBehavior : NSStatusItemBehaviorRemovalAllowed ];
    if ([self shouldHideFromMenuBar]) {
        [ statusItem setVisible : NO ];
    } else {
        [ statusItem setVisible : YES ];
    }

    [self updateStartupItemState];
    [self updatePauseState];
    [self updateOptionState];

    eventPort = CGEventTapCreate( kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, CGEventMaskBit(NX_SYSDEFINED), tapEventCallback, (__bridge void * _Nullable)(self));
    if ( eventPort == NULL )
    {
    	eventPort = CGEventTapCreate( kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, NX_SYSDEFINEDMASK, tapEventCallback, (__bridge void * _Nullable)(self));
	}

    if ( eventPort != NULL )
    {

		eventPortSource = CFMachPortCreateRunLoopSource( kCFAllocatorSystemDefault, eventPort, 0 );

		[self startEventSession];

	}
	else
	{

		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText:@"Error"];
		[alert setInformativeText:@"Cannot start event listening. Please add Mac Media Key Forwarder to the \"Privacy & Security\" pane in System Settings."];
		[alert addButtonWithTitle:@"Ok"];
		[alert runModal];

		exit(0);

	}

}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    if ([self shouldHideFromMenuBar]) {
        [self setHideFromMenuBar:NO];
        [statusItem setVisible: YES];
    }

    return YES;
}

- ( void ) startEventSession
{
    if (pauseState != PauseStatePause && !CFRunLoopContainsSource(CFRunLoopGetCurrent(), eventPortSource, kCFRunLoopCommonModes)) {
        CFRunLoopAddSource( CFRunLoopGetCurrent(), eventPortSource, kCFRunLoopCommonModes );
    }
}

- ( void ) stopEventSession
{
    if (CFRunLoopContainsSource(CFRunLoopGetCurrent(), eventPortSource, kCFRunLoopCommonModes)) {
        CFRunLoopRemoveSource( CFRunLoopGetCurrent(), eventPortSource, kCFRunLoopCommonModes );
    }
}

- ( void ) terminate
{
    [ NSApp terminate : nil ];
}

- ( void ) support
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: @"https://paypal.me/milgra"]];
}

- ( void ) update
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: @"https://github.com/haad/macmediakeyforwarder/releases"]];
}


#pragma mark - Secondary app selection

- (void)selectSpotifySecondary
{
    secondaryApp = SecondaryAppSpotify;
    [[NSUserDefaults standardUserDefaults] setObject:@(secondaryApp) forKey:kUserDefaultsPriorityOptionKey];
    [self updateOptionState];
}

- (void)selectMusicSecondary
{
    secondaryApp = SecondaryAppMusic;
    [[NSUserDefaults standardUserDefaults] setObject:@(secondaryApp) forKey:kUserDefaultsPriorityOptionKey];
    [self updateOptionState];
}

- (void)manualPause
{
    if ( pauseState != PauseStatePause )
    {
        pauseState = PauseStatePause;
        [self stopEventSession];
    }
    else
    {
        pauseState = PauseStateNone;
        [self startEventSession];
    }

    [[NSUserDefaults standardUserDefaults] setObject:@(pauseState) forKey:kUserDefaultsPauseOptionKey];
    [self updatePauseState];
}

- (void)autoPause
{
    if ( pauseState != PauseStateAutomatic )
    {
        pauseState = PauseStateAutomatic;
    }
    else
    {
        pauseState = PauseStateNone;
    }
    [[NSUserDefaults standardUserDefaults] setObject:@(pauseState) forKey:kUserDefaultsPauseOptionKey];
    [self updatePauseState];

    [self startEventSession];
}

#pragma mark - Startup Item
- (void)toggleStartupItem {
    if ( [GBLaunchAtLogin isLoginItem] ) {
        [GBLaunchAtLogin removeAppFromLoginItems];
    }
    else {
        [GBLaunchAtLogin addAppAsLoginItem];
    }

    [self updateStartupItemState];
}

- (void)hideFromMenuBar
{
    [self setHideFromMenuBar:YES];

    if ([GBLaunchAtLogin isLoginItem] == NO) {
        [GBLaunchAtLogin addAppAsLoginItem];
    }

    [statusItem setVisible: NO];
}

- (void)setHideFromMenuBar:(BOOL)hidden
{
    [[NSUserDefaults standardUserDefaults] setBool:hidden forKey:kUserDefaultsHideFromMenuBarOptionKey];
}

- (BOOL)shouldHideFromMenuBar
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kUserDefaultsHideFromMenuBarOptionKey];
}

#pragma mark - UI refresh

- (void)updateOptionState
{
    // Verify if a choice was selected, otherwise mark Spotify as the default

    NSNumber *option = [[NSUserDefaults standardUserDefaults] valueForKey:kUserDefaultsPriorityOptionKey];
    if ( option )
    {
        secondaryApp = [option integerValue];
    }

    // Mark with a tick the selected item from priority options

    for ( NSUInteger index = 0, num = priorityOptionItems.count; index < num; index++ )
    {
        NSMenuItem *item = priorityOptionItems[index];
        [item setState:( index == secondaryApp ? NSControlStateValueOn : NSControlStateValueOff )];
    }
}

- (void)updatePauseState
{
    NSMenuItem *item0 = pauseOptionItems[0];
    NSMenuItem *item1 = pauseOptionItems[1];

    [item0 setState: pauseState == PauseStatePause ? NSControlStateValueOn : NSControlStateValueOff];
    [item1 setState: pauseState == PauseStateAutomatic ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)updateStartupItemState {
    [startupItem setState: [GBLaunchAtLogin isLoginItem] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self updateStartupItemState];
}

- (NSImage *)menuImageWithSymbol:(NSString *)symbolName
{
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
    return [image imageWithSymbolConfiguration:config];
}

@end
