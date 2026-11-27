/*
 * FlyDigi's bundled floating menu (and FLEX) expect a classic UIKit app
 * lifecycle where `[UIApplication sharedApplication].delegate` has a `window`
 * property. iDared32bit uses SDL, whose delegate is scene-based
 * (`SDLUIKitSceneDelegate`) and does not implement `-window`, so the FlyDigi
 * SDK crashes with an unrecognized selector at launch.
 *
 * This category answers `-window` for any object (the FlyDigi code asks the
 * scene delegate) by returning the foreground scene's key window, which is
 * SDL's own render window. Uiview's own `-window` still takes precedence, so
 * nothing else changes behaviour.
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