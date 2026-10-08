import Foundation
import ObjectiveC
import Darwin

// Two-pronged approach to activate wantsLiveScene for our widget:
//
// 1. Patch CHSMutableWidgetDescriptor.setKind: (the original approach) — works if
//    HomeBoard.framework is loadable in the extension process.
//
// 2. Find LiveSceneWidgetConfiguration in WidgetKit at runtime and call it from
//    body via makeLiveSceneConfiguration() — the correct approach if (1) fails,
//    since the descriptor is created in SpringBoard's process, not ours.
//
// 3. Write an extension-process diagnostic to a tmp path so the main app can
//    read it via bad_query and we can see exactly what classes are available.

enum WallpaperBootstrap {

    private static var origSetKind: IMP?
    private static var installed = false

    // MARK: - Install (called from PhysicsWallpaperBundle.init)

    static func install() {
        guard !installed else { return }
        installed = true

        var diag: [String] = ["=== WallpaperBootstrap (extension process) ==="]

        // ── Force-load private frameworks ────────────────────────────────────
        let frameworks = [
            "/System/Library/Frameworks/WidgetKit.framework/WidgetKit",
            "/System/Library/PrivateFrameworks/HomeBoard.framework/HomeBoard",
            "/System/Library/PrivateFrameworks/CoreHomeScreen.framework/CoreHomeScreen",
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
        ]
        for path in frameworks {
            let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
            diag.append("dlopen \((path as NSString).lastPathComponent): \(h != nil ? "OK" : "FAIL")")
        }

        // ── Enumerate WidgetKit classes looking for LiveScene ─────────────────
        let wkPath = "/System/Library/Frameworks/WidgetKit.framework/WidgetKit"
        var imageCount: UInt32 = 0
        if let names = objc_copyClassNamesForImage(wkPath, &imageCount) {
            var liveSceneClasses: [String] = []
            for i in 0..<Int(imageCount) {
                let n = String(cString: names[i])
                if n.lowercased().contains("livescene") || n.lowercased().contains("live_scene") {
                    liveSceneClasses.append(n)
                }
            }
            free(UnsafeMutableRawPointer(names))
            diag.append("WidgetKit LiveScene classes: \(liveSceneClasses.joined(separator: ", "))")
            WallpaperBootstrap.liveSceneClassNames = liveSceneClasses
        } else {
            diag.append("WidgetKit class enumeration: nil")
        }

        // ── Patch CHSMutableWidgetDescriptor ─────────────────────────────────
        let classNames = [
            "CHSMutableWidgetDescriptor",
            "CHSWidgetDescriptor",
            "_CHSMutableWidgetDescriptor",
        ]
        var patched = false
        for className in classNames {
            if let cls = NSClassFromString(className),
               let method = class_getInstanceMethod(cls, NSSelectorFromString("setKind:")) {
                patchSetKind(on: cls, method: method)
                diag.append("Patched \(className).setKind:")
                patched = true
                break
            } else {
                diag.append("NSClassFromString(\(className)): nil")
            }
        }
        if !patched {
            diag.append("CHSMutableWidgetDescriptor: not found in extension process")
        }

        // ── Write diagnostic ──────────────────────────────────────────────────
        // Write to NSTemporaryDirectory so bad_query can reach it
        // AND to the extension's own container if accessible.
        let text = diag.joined(separator: "\n")
        let tmpPath = NSTemporaryDirectory() + "pp_ext_bootstrap.txt"
        try? text.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        // Also attempt write to shared group if available
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.mak5er.Pocket-Poster") {
            try? text.write(to: groupURL.appendingPathComponent("pp_ext_bootstrap.txt"),
                            atomically: true, encoding: .utf8)
        }
    }

    // MARK: - LiveSceneWidgetConfiguration factory (called from PhysicsWallpaperBundle.body)

    static var liveSceneClassNames: [String] = []

    /// Try to instantiate LiveSceneWidgetConfiguration at runtime.
    /// Returns nil if the class is not available in this process.
    static func makeLiveSceneConfiguration(kind: String) -> AnyObject? {
        // Candidate ObjC-bridged class names for LiveSceneWidgetConfiguration
        let candidates = liveSceneClassNames + [
            "_TtC9WidgetKit27LiveSceneWidgetConfiguration",
            "LiveSceneWidgetConfiguration",
            "WKLiveSceneWidgetConfiguration",
            "_LiveSceneWidgetConfiguration",
        ]

        for className in candidates {
            guard let cls = NSClassFromString(className) else { continue }

            // Try init(kind:)
            let kindSel = NSSelectorFromString("initWithKind:")
            if let initMethod = class_getInstanceMethod(cls, kindSel) {
                typealias InitKindFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
                let imp = method_getImplementation(initMethod)
                if let instance = cls as? NSObject.Type {
                    // alloc() is unavailable in Swift — call via ObjC runtime
                    let allocSel = NSSelectorFromString("alloc")
                    guard let obj = (instance as AnyObject).perform(allocSel)?.takeUnretainedValue() else { continue }
                    let result = unsafeBitCast(imp, to: InitKindFn.self)(
                        obj, kindSel, kind as NSString)
                    return result
                }
            }

            // Try plain init
            if let instance = cls as? NSObject.Type {
                let obj = instance.init()
                return obj
            }
        }
        return nil
    }

    // MARK: - CHSMutableWidgetDescriptor swizzle

    private static func patchSetKind(on cls: AnyClass, method: Method) {
        let wantsSel = NSSelectorFromString("setWantsLiveScene:")
        let ourKind  = "com.mak5er.Pocket-Poster.physics-wallpaper"

        let block: @convention(block) (AnyObject, NSString) -> Void = { obj, kind in
            if let orig = WallpaperBootstrap.origSetKind {
                typealias SetKindFn = @convention(c) (AnyObject, Selector, NSString) -> Void
                unsafeBitCast(orig, to: SetKindFn.self)(
                    obj, NSSelectorFromString("setKind:"), kind)
            }
            guard (kind as String) == ourKind else { return }
            if let m = class_getInstanceMethod(type(of: obj), wantsSel) {
                typealias SetBoolFn = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(m), to: SetBoolFn.self)(obj, wantsSel, true)
            }
        }

        let newIMP = imp_implementationWithBlock(block)
        WallpaperBootstrap.origSetKind = method_setImplementation(method, newIMP)
    }
}
