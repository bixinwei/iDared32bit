/*
 * FlyDigi's bundled floating menu (and FLEX) expects a classic UIKit app
 * lifecycle where `[UIApplication sharedApplication].delegate` has a `window`
 * property. iDared32bit uses SDL, whose delegate is scene-based
 * (`SDLUIKitSceneDelegate`) and does not implement `-window`, so the FlyDigi
 * SDK crashes with an unrecognized selector at launch.
 *
 * This category answers `-window` for any object that FlyDigi asks (the scene
 * delegate) by returning the foreground scene's key window, which is SDL's own
 * render window. UIView's own `-window` still takes precedence, so nothing
 * else changes behaviour.
 */

#import <UIKit/UIKit.h>

@implementation NSObject (FlyDigiWindow)

- (UIWindow *)window {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindow *key = windowScene.keyWindow;
        if (key) {
            return key;
        }
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
        if (windowScene.windows.count > 0) {
            return windowScene.windows.firstObject;
        }
    }
    return nil;
}

@end

/*
 * SDL renders with a full-screen Metal layer, and its window sits at a high
 * window level. FlyDigi's floating UI lives in its own `FZUIWindow` (and FLEX's
 * windows), which come up at a normal level and get drawn *under* SDL, so they
 * are invisible. A repeating keeper forces every FZ*/FLEX window above the
 * SDL window's level.
 */

static UIWindow *flydigi_sdl_window(void) {
    Class sdlVC = NSClassFromString(@"SDL_uikitviewcontroller");
    if (!sdlVC) {
        return nil;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window.rootViewController isKindOfClass:sdlVC]) {
                return window;
            }
        }
    }
    return nil;
}

static void flydigi_raise_overlays(void) {
    UIWindow *sdl = flydigi_sdl_window();
    if (!sdl) {
        return;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window == sdl || window.hidden) {
                continue;
            }
            NSString *name = NSStringFromClass(window.class);
            if ([name hasPrefix:@"FZ"] || [name hasPrefix:@"FLEX"]) {
                if (window.windowLevel <= sdl.windowLevel) {
                    window.windowLevel = sdl.windowLevel + 1;
                }
            }
        }
    }
}

void idared_start_flydigi_window_keeper(void) {
    static NSTimer *keeper;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flydigi_raise_overlays();
        keeper = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
            flydigi_raise_overlays();
        }];
        [[NSRunLoop mainRunLoop] addTimer:keeper forMode:NSRunLoopCommonModes];
    });
}