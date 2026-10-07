import Foundation
import ObjectiveC
import Darwin

// Patches CHSMutableWidgetDescriptor so our widget kind gets
// wantsLiveScene = YES.  Call install() once before WidgetKit
// processes the configuration — done from PhysicsWallpaperBundle.init().
//
// CHSMutableWidgetDescriptor lives in HomeBoard.framework (or SpringBoardServices).
// The extension process doesn't load it automatically, so we dlopen the framework
// first so NSClassFromString can find the class.

enum WallpaperBootstrap {

    private static var origSetKind: IMP?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        // Force-load frameworks that may contain CHSMutableWidgetDescriptor.
        // The class is defined in HomeBoard/CoreHomeScreen; WidgetKit extensions
        // do not link these by default, so NSClassFromString returns nil without
        // an explicit dlopen.
        let frameworkPaths: [String] = [
            "/System/Library/PrivateFrameworks/HomeBoard.framework/HomeBoard",
            "/System/Library/PrivateFrameworks/CoreHomeScreen.framework/CoreHomeScreen",
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
        ]
        for path in frameworkPaths {
            dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        }

        // Also try to find wantsLiveScene in WidgetKit itself — some iOS 26 builds
        // moved CHSMutableWidgetDescriptor into a WidgetKit-adjacent private class.
        let widgetKitPath = "/System/Library/Frameworks/WidgetKit.framework/WidgetKit"
        dlopen(widgetKitPath, RTLD_NOW | RTLD_GLOBAL)

        // Try the canonical name and a few iOS-version-specific mangled names.
        let classNames = [
            "CHSMutableWidgetDescriptor",
            "CHSWidgetDescriptor",
            "_CHSMutableWidgetDescriptor",
            "WKMutableWidgetDescriptor",
        ]

        for className in classNames {
            guard
                let cls = NSClassFromString(className),
                let method = class_getInstanceMethod(cls, NSSelectorFromString("setKind:"))
            else { continue }

            patchSetKind(on: cls, method: method)
            break
        }
    }

    private static func patchSetKind(on cls: AnyClass, method: Method) {
        let wantsSel = NSSelectorFromString("setWantsLiveScene:")

        let block: @convention(block) (AnyObject, NSString) -> Void = { obj, kind in
            // Call the original implementation.
            if let orig = WallpaperBootstrap.origSetKind {
                typealias SetKindFn = @convention(c) (AnyObject, Selector, NSString) -> Void
                unsafeBitCast(orig, to: SetKindFn.self)(
                    obj, NSSelectorFromString("setKind:"), kind)
            }

            guard (kind as String) == "com.mak5er.Pocket-Poster.physics-wallpaper" else { return }

            // Invoke setWantsLiveScene:YES directly via IMP (can't use
            // perform(_:with:) for BOOL parameters without boxing).
            if let wantsMethod = class_getInstanceMethod(type(of: obj), wantsSel) {
                let imp = method_getImplementation(wantsMethod)
                typealias SetBoolFn = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(imp, to: SetBoolFn.self)(obj, wantsSel, true)
            }
        }

        let newIMP = imp_implementationWithBlock(block)
        WallpaperBootstrap.origSetKind = method_setImplementation(method, newIMP)
    }
}
