//
//  SymHandler.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import SQLite3
import Darwin

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

        // ── Show what's inside our written descriptor folder ───────────────────
        // Confirms files landed correctly and reveals the format we're writing.
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
                                diag.append("    \(f) [plist]: \(String(describing: plist).prefix(500))")
                            } else {
                                diag.append("    \(f): [binary \(data.count)b]")
                            }
                        } else {
                            // It's a directory — list and recurse one level
                            if let subH = try? BadQuery.consume(path: filePath, create: true) {
                                defer { subH.release() }
                                let subItems = (try? fm.contentsOfDirectory(atPath: filePath)) ?? []
                                diag.append("    \(f)/: \(subItems.joined(separator: ","))")
                                for si in subItems where !si.hasPrefix(".") {
                                    let siPath = "\(filePath)/\(si)"
                                    if let siH = try? BadQuery.consume(path: siPath, create: true) {
                                        defer { siH.release() }
                                        if let siData = fm.contents(atPath: siPath) {
                                            if let s = String(data: siData, encoding: .utf8) {
                                                diag.append("      \(f)/\(si): \(s.prefix(100))")
                                            } else if let pl = try? PropertyListSerialization.propertyList(
                                                from: siData, options: [], format: nil) {
                                                diag.append("      \(f)/\(si) [plist]: \(String(describing: pl).prefix(400))")
                                            } else {
                                                diag.append("      \(f)/\(si): [binary \(siData.count)b]")
                                            }
                                        } else {
                                            let subSub = (try? fm.contentsOfDirectory(atPath: siPath)) ?? []
                                            diag.append("      \(f)/\(si)/: \(subSub.joined(separator: ","))")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            diag.append("ourDesc: not accessible (path=\(ourDescPath))")
        }

        // ── GalleryCache — PB's serialized collection list (ground truth for schema) ──────
        let galleryCachePath = BadQuery.applicationContainerPath(appHash: appHash) +
            "/Library/Application Support/PRBPosterExtensionDataStore/61/GalleryCache"
        if let gcH = try? BadQuery.consume(path: galleryCachePath, create: true) {
            defer { gcH.release() }
            let gcFiles = (try? fm.contentsOfDirectory(atPath: galleryCachePath)) ?? []
            for gcFile in gcFiles where gcFile.hasSuffix(".plist") {
                let gcFilePath = "\(galleryCachePath)/\(gcFile)"
                if let gcData = fm.contents(atPath: gcFilePath),
                   let gcPlist = try? PropertyListSerialization.propertyList(
                       from: gcData, options: [], format: nil) {
                    let s = String(describing: gcPlist)
                    // Log up to 3000 chars — truncate if longer
                    let lines = stride(from: 0, to: min(s.count, 3000), by: 200).map {
                        String(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: min($0+200, s.count))])
                    }
                    diag.append("GalleryCache \(gcFile) [\(s.count) chars]:")
                    lines.forEach { diag.append("  \($0)") }
                }
            }
        } else {
            diag.append("GalleryCache: not accessible")
        }

        // ── Probe shouldLoadWallpaperCollectionAtURL: and shouldLoadWallpaperBundleAtURL: ──
        // These class methods are the gatekeepers iOS 26.5 _loadCollections uses.
        // Unlike _loadCollections itself, these just check files on disk — no process context needed.
        dlopen("/System/Library/PrivateFrameworks/WallpaperKit.framework/WallpaperKit", RTLD_NOW)
        let ourDescURL = URL(fileURLWithPath: ourDescPath)

        func shouldLoadColl() -> Bool {
            guard let cls = objc_getClass("WKWallpaperRepresentingCollection"),
                  let meta = object_getClass(cls as AnyObject) else { return false }
            let sel = Selector("shouldLoadWallpaperCollectionAtURL:")
            guard let m = class_getInstanceMethod(meta, sel) else { return false }
            typealias F = @convention(c) (AnyObject, Selector, NSURL) -> Bool
            return unsafeBitCast(method_getImplementation(m), to: F.self)(
                cls as AnyObject, sel, ourDescURL as NSURL)
        }
        func shouldLoadBundle(_ uuid: String) -> Bool {
            guard let cls = objc_getClass("WKWallpaperBundle"),
                  let meta = object_getClass(cls as AnyObject) else { return false }
            let sel = Selector("shouldLoadWallpaperBundleAtURL:")
            guard let m = class_getInstanceMethod(meta, sel) else { return false }
            typealias F = @convention(c) (AnyObject, Selector, NSURL) -> Bool
            let url = ourDescURL.appendingPathComponent(uuid) as NSURL
            return unsafeBitCast(method_getImplementation(m), to: F.self)(cls as AnyObject, sel, url)
        }

        diag.append("shouldLoadCollectionAtURL(descriptors/): \(shouldLoadColl())")

        // Find first UUID folder (not Collection.plist)
        var firstBundleUUID: String? = nil
        if let dHx = try? BadQuery.consume(path: ourDescPath, create: true) {
            defer { dHx.release() }
            let uuidsX = (try? fm.contentsOfDirectory(atPath: ourDescPath)) ?? []
            firstBundleUUID = uuidsX.first(where: { !$0.hasPrefix(".") && $0 != "Collection.plist" })
        }

        if let uuid = firstBundleUUID {
            diag.append("shouldLoadBundleAtURL(\(uuid.prefix(8))): \(shouldLoadBundle(uuid))")

            // Test: write minimal Wallpaper.plist to UUID folder and immediately re-probe.
            // Determines if shouldLoadWallpaperBundleAtURL: only checks file existence
            // (i.e. does Wallpaper.plist need to exist, regardless of content?).
            let bundleDir = ourDescURL.appendingPathComponent(uuid)
            let wpPlistURL = bundleDir.appendingPathComponent("Wallpaper.plist")
            let wpMeta: [String: Any] = ["identifier": "pp-\(uuid.prefix(8))", "version": 1, "name": "Custom WP"]
            if let wpData = try? PropertyListSerialization.data(
                fromPropertyList: wpMeta, format: .xml, options: 0),
               let bdH = try? BadQuery.consume(path: bundleDir.path, create: true) {
                defer { bdH.release() }
                try? wpData.write(to: wpPlistURL)
                diag.append("shouldLoadBundleAtURL after Wallpaper.plist: \(shouldLoadBundle(uuid))")
                diag.append("shouldLoadCollectionAtURL after Wallpaper.plist: \(shouldLoadColl())")
            } else {
                diag.append("Wallpaper.plist test write failed")
            }
        }

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
}
