//
//  LiveWidgetActivator.swift
//  Pocket Poster
//
//  Option 2: direct widget descriptor write via bad_query.
//  Finds SpringBoard/homeboardd's InternalDaemon container, discovers
//  where WidgetKit stores widget instance descriptors, and writes a
//  descriptor for the physics wallpaper extension with wantsLiveScene = YES.
//

import Foundation
import Darwin

enum LiveWidgetActivator {

    static let physicsWidgetKind       = "com.mak5er.Pocket-Poster.physics-wallpaper"
    // Extension bundle ID will have the team-suffix in production builds.
    // We search by prefix so either form matches.
    static let physicsExtensionPrefix  = "com.mak5er.Pocket-Poster"

    // Bundle IDs of daemons that may own widget descriptor storage.
    private static let candidateBundleIds: [String] = [
        "com.apple.springboard",
        "com.apple.SpringBoard",
        "com.apple.homeboardd",
        "com.apple.backboardd",
        "com.apple.frontboard.systemappservices",
        "com.apple.frontboard.launchservicesserver",
    ]

    private static let internalDaemonRoot = "/var/mobile/Containers/Data/InternalDaemon"
    private static let applicationRoot    = "/var/mobile/Containers/Data/Application"
    private static let pluginRoot         = "/var/mobile/Containers/Data/PluginKitPlugin"

    // MARK: - Public entry point

    /// Call after the CAML/posterboardd descriptor write.
    /// Scans InternalDaemon containers for SpringBoard/homeboardd, explores
    /// their Library for WidgetKit widget descriptor files, then attempts to
    /// write a descriptor entry with wantsLiveScene = YES.
    static func activate() {
        var diag: [String] = ["=== LiveWidgetActivator ==="]
        defer {
            let text = diag.joined(separator: "\n")
            try? text.write(
                to: SymHandler.getLCDocumentsDirectory()
                    .appendingPathComponent("live_widget_diag.txt"),
                atomically: true, encoding: .utf8)
        }

        // ── 1. Find the physics extension's PluginKitPlugin container hash ──
        if let extHash = findContainerHash(bundleIdPrefix: physicsExtensionPrefix,
                                           in: pluginRoot, diag: &diag) {
            diag.append("Physics extension container: \(extHash)")
            exploreContainer(root: pluginRoot, hash: extHash, label: "PhysicsExt",
                             diag: &diag)
        } else {
            diag.append("Physics extension container: not found in PluginKitPlugin")
        }

        // ── 2. Find SpringBoard / homeboardd InternalDaemon container ───────
        guard let (targetHash, targetBID) = findDaemonContainer(diag: &diag) else {
            diag.append("FAIL: no candidate daemon found in InternalDaemon")
            return
        }
        diag.append("Daemon found: \(targetBID) hash=\(targetHash)")

        // ── 3. Explore the daemon container for widget-related files ─────────
        let daemonRoot = "\(internalDaemonRoot)/\(targetHash)"
        exploreContainer(root: internalDaemonRoot, hash: targetHash,
                         label: targetBID, diag: &diag)

        // ── 4. Attempt to write wantsLiveScene into any discovered descriptor ─
        let libPath = "\(daemonRoot)/Library"
        writeWantsLiveScene(inLibrary: libPath, diag: &diag)

        diag.append("=== done ===")
    }

    // MARK: - Container discovery

    private static func findDaemonContainer(diag: inout [String]) -> (hash: String, bid: String)? {
        guard let h = try? BadQuery.consume(path: internalDaemonRoot, create: true) else {
            diag.append("InternalDaemon root: no access"); return nil
        }
        h.release()

        let dirs = (try? BadQuery.list(path: internalDaemonRoot)) ?? []
        diag.append("InternalDaemon UUIDs scanned: \(dirs.count)")

        for dir in dirs {
            let uuid = (dir as NSString).lastPathComponent
            let metaPath = "\(internalDaemonRoot)/\(uuid)/.com.apple.mobile_container_manager.metadata.plist"
            guard let mH = try? BadQuery.consume(path: metaPath, create: true) else { continue }
            mH.release()
            guard let dict = NSDictionary(contentsOfFile: metaPath) as? [String: Any],
                  let bid  = dict["MCMMetadataIdentifier"] as? String else { continue }

            let bidL = bid.lowercased()
            let isCandidate = candidateBundleIds.contains(where: { $0.lowercased() == bidL }) ||
                              bidL == "com.apple.springboard" ||
                              bidL.contains("homeboardd")
            diag.append("  ID \(uuid.prefix(8)): \(bid)\(isCandidate ? " ←" : "")")

            if isCandidate {
                return (uuid, bid)
            }
        }
        return nil
    }

    private static func findContainerHash(bundleIdPrefix: String, in root: String,
                                          diag: inout [String]) -> String? {
        guard let h = try? BadQuery.consume(path: root, create: true) else { return nil }
        h.release()
        let dirs = (try? BadQuery.list(path: root)) ?? []
        for dir in dirs {
            let uuid = (dir as NSString).lastPathComponent
            let metaPath = "\(root)/\(uuid)/.com.apple.mobile_container_manager.metadata.plist"
            guard let mH = try? BadQuery.consume(path: metaPath, create: true) else { continue }
            mH.release()
            guard let dict = NSDictionary(contentsOfFile: metaPath) as? [String: Any],
                  let bid  = dict["MCMMetadataIdentifier"] as? String else { continue }
            if bid.hasPrefix(bundleIdPrefix) {
                return uuid
            }
        }
        return nil
    }

    // MARK: - Container exploration (diagnostic)

    private static func exploreContainer(root: String, hash: String, label: String,
                                         diag: inout [String]) {
        let containerPath = "\(root)/\(hash)"
        guard let cH = try? BadQuery.consume(path: containerPath, create: true) else {
            diag.append("[\(label)] container not accessible"); return
        }
        cH.release()

        let libPath = "\(containerPath)/Library"
        guard let lH = try? BadQuery.consume(path: libPath, create: true) else {
            diag.append("[\(label)] Library not accessible"); return
        }
        lH.release()

        let libContents = (try? FileManager.default.contentsOfDirectory(atPath: libPath)) ?? []
        diag.append("[\(label)] Library/: \(libContents.joined(separator: ", "))")

        for sub in libContents where !sub.hasPrefix(".") {
            let subPath = "\(libPath)/\(sub)"
            guard let sH = try? BadQuery.consume(path: subPath, create: true) else { continue }
            sH.release()

            let subItems = (try? FileManager.default.contentsOfDirectory(atPath: subPath)) ?? []
            diag.append("[\(label)]   \(sub)/: \(subItems.joined(separator: ", "))")

            for item in subItems where !item.hasPrefix(".") {
                let itemPath = "\(subPath)/\(item)"
                inspectPath(path: itemPath, label: "[\(label)]    \(sub)/\(item)", diag: &diag)
            }
        }
    }

    private static func inspectPath(path: String, label: String, diag: inout [String]) {
        let fm = FileManager.default
        if let data = fm.contents(atPath: path) {
            if let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                diag.append("\(label) [plist]: \(String(describing: pl).prefix(600))")
            } else if let str = String(data: data, encoding: .utf8) {
                diag.append("\(label): \(str.prefix(300))")
            } else {
                diag.append("\(label): [bin \(data.count)b]")
            }
        } else if let iH = try? BadQuery.consume(path: path, create: true) {
            iH.release()
            let sub = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            diag.append("\(label)/: \(sub.joined(separator: ", "))")
        }
    }

    // MARK: - wantsLiveScene descriptor write

    /// Walk the daemon's Library directory looking for widget descriptor plists
    /// or SQLite DBs, then patch them to set wantsLiveScene = YES for our widget.
    private static func writeWantsLiveScene(inLibrary libPath: String, diag: inout [String]) {
        guard let lH = try? BadQuery.consume(path: libPath, create: true) else {
            diag.append("wantsLiveScene: Library not accessible"); return
        }
        lH.release()

        let libContents = (try? FileManager.default.contentsOfDirectory(atPath: libPath)) ?? []

        // Known potential paths for WidgetKit widget descriptor storage:
        // - Library/WidgetKit/  (WidgetKit-specific data)
        // - Library/SpringBoard/  (legacy home screen state)
        // - Library/HomeBoard/
        // - Library/Preferences/  (could have a WidgetKit preferences file)
        let widgetDirs = libContents.filter { sub in
            let sl = sub.lowercased()
            return sl.contains("widget") || sl.contains("home") || sl.contains("spring") ||
                   sl.contains("board") || sl.contains("icon")
        }
        diag.append("wantsLiveScene candidate dirs: \(widgetDirs.joined(separator: ", "))")

        for sub in widgetDirs {
            let subPath = "\(libPath)/\(sub)"
            guard let sH = try? BadQuery.consume(path: subPath, create: true) else { continue }
            sH.release()

            let items = (try? FileManager.default.contentsOfDirectory(atPath: subPath)) ?? []
            diag.append("  \(sub)/: \(items.joined(separator: ", "))")

            for item in items where !item.hasPrefix(".") {
                let itemPath = "\(subPath)/\(item)"
                // Attempt plist patch
                if patchWidgetPlist(at: itemPath, diag: &diag) { continue }
                // Deep scan subdirectory
                if let iH = try? BadQuery.consume(path: itemPath, create: true) {
                    iH.release()
                    let subItems = (try? FileManager.default.contentsOfDirectory(atPath: itemPath)) ?? []
                    for si in subItems where si.hasSuffix(".plist") || si.hasSuffix(".db") {
                        _ = patchWidgetPlist(at: "\(itemPath)/\(si)", diag: &diag)
                    }
                }
            }
        }

        // Also try direct known paths regardless of directory scan result
        let directPaths = [
            "\(libPath)/SpringBoard/iconState.plist",
            "\(libPath)/SpringBoard/currentIconState.plist",
            "\(libPath)/WidgetKit/widgetDescriptors.plist",
            "\(libPath)/HomeBoard/widgetDescriptors.plist",
        ]
        for dp in directPaths {
            _ = patchWidgetPlist(at: dp, diag: &diag)
        }
    }

    /// Attempt to patch a plist file to set wantsLiveScene = YES for our widget kind.
    /// Returns true if the file was found and modified (or already correct).
    @discardableResult
    private static func patchWidgetPlist(at path: String, diag: inout [String]) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any]
        else { return false }

        // Search the plist recursively for our widget kind and patch wantsLiveScene.
        var changed = false
        patchRecursive(&plist, diag: &diag, path: path, changed: &changed)

        if changed {
            if let newData = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0) {
                do {
                    try newData.write(to: URL(fileURLWithPath: path))
                    diag.append("PATCHED \(path.split(separator: "/").suffix(3).joined(separator: "/"))")
                    return true
                } catch {
                    diag.append("WRITE FAIL \(path): \(error)")
                }
            }
        }
        return false
    }

    private static func patchRecursive(_ dict: inout [String: Any], diag: inout [String],
                                       path: String, changed: inout Bool) {
        // If this dict looks like a widget descriptor for our kind, patch it.
        if let kind = dict["widgetKind"] as? String, kind == physicsWidgetKind {
            if dict["wantsLiveScene"] as? Bool != true {
                dict["wantsLiveScene"] = true
                changed = true
                diag.append("  patched wantsLiveScene in widgetKind=\(kind) at \(path)")
            }
        }
        if let kind = dict["kind"] as? String, kind == physicsWidgetKind {
            if dict["wantsLiveScene"] as? Bool != true {
                dict["wantsLiveScene"] = true
                changed = true
                diag.append("  patched wantsLiveScene in kind=\(kind) at \(path)")
            }
        }

        // Recurse into nested dicts and arrays.
        for key in dict.keys {
            if var subDict = dict[key] as? [String: Any] {
                patchRecursive(&subDict, diag: &diag, path: path, changed: &changed)
                dict[key] = subDict
            } else if var arr = dict[key] as? [[String: Any]] {
                for i in arr.indices {
                    patchRecursive(&arr[i], diag: &diag, path: path, changed: &changed)
                }
                dict[key] = arr
            }
        }
    }

    // MARK: - Darwin notification broadcast

    /// Post every widget/homescreen reload notification we know about to trigger
    /// SpringBoard to re-read the widget descriptor store.
    static func postReloadNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let names: [String] = [
            "com.apple.WidgetKit.dataChanged",
            "com.apple.WidgetKit.reloadAll",
            "com.apple.springboard.widgetsChanged",
            "com.apple.springboard.homescreen.reload",
            "com.apple.homeboardd.widgetDataChanged",
            "com.apple.homeboardd.reload",
            "com.apple.WidgetKit.widgetDescriptorChanged",
            "com.apple.springboard.requiresDeviceUnlock",
        ]
        for name in names {
            CFNotificationCenterPostNotification(
                center, CFNotificationName(name as CFString), nil, nil, true)
        }
    }
}
