import Foundation
import ObjectiveC

// Patches CHSMutableWidgetDescriptor at load time so that our widget kind
// gets wantsLiveScene = YES.  CHSMutableWidgetDescriptor lives in
// WidgetKit.framework which is already linked by the extension, so the class
// is present in our process.  We use imp_implementationWithBlock to replace
// setKind: with a wrapper that also calls setWantsLiveScene: for our bundle.
//
// @_silgen_name("__ZN...") would be cleaner but requires the exact mangled
// symbol.  The ObjC runtime approach below is stable across minor OS updates.

@objc(PWEWallpaperBootstrap)
final class WallpaperBootstrap: NSObject {

    private static var origSetKind: IMP?

    @objc static func load() {
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

            guard (kind as String) == "com.mak5er.pocketposter.physics-wallpaper" else { return }

            // Directly invoke setWantsLiveScene: via IMP so we can pass a Bool.
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
