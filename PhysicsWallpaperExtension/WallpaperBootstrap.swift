import Foundation
import ObjectiveC

// Patches CHSMutableWidgetDescriptor so our widget kind gets
// wantsLiveScene = YES.  Call install() once before WidgetKit
// processes the configuration — done from PhysicsWallpaperBundle.init().

enum WallpaperBootstrap {

    private static var origSetKind: IMP?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        guard
            let cls = NSClassFromString("CHSMutableWidgetDescriptor"),
            let method = class_getInstanceMethod(cls, NSSelectorFromString("setKind:"))
        else { return }

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
