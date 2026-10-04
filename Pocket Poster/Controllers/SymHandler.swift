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

        // ══════════════════════════════════════════════════════════════════════
        // APPROACH DIRECT — delete PB's DB files using dir extension, then call
        // sqlite3_open_v2(dbPath, CREATE) directly at PB's path.
        // Hypothesis: POSIX O_CREAT on a non-existent path may work (while O_RDWR
        // on an existing file fails with EISDIR in LiveContainer).  No copy needed.
        // ══════════════════════════════════════════════════════════════════════
        var didSucceed = false

        if let dirHandle = try? BadQuery.consume(path: dbDir, create: true) {
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

        do {
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

        // ── post Darwin notifications to trigger PB rescan ───────────────────
        // Fire-and-forget; wrong names are a no-op. Right name = PB rescans
        // and shows our wallpaper without waiting for the next respring.
        if didSucceed {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let candidates: [String] = [
                "com.apple.springboard.posterboard.wallpapersDidChange",
                "com.apple.UIPosterBoard.wallpapersChanged",
                "com.apple.posterboard.newPosterAvailable",
                "com.apple.posterboardd.posterDataChanged",
                "PRBPosterExtensionDataStoreChanged",
                "com.apple.posterboard.reload",
            ]
            for name in candidates {
                CFNotificationCenterPostNotification(center,
                    CFNotificationName(name as CFString), nil, nil, true)
            }
            diag.append("posted \(candidates.count) Darwin notification candidates")

            // ── kill posterboardd so launchd restarts it with a fresh DB read ──
            // posterboardd is a persistent daemon that survives respring — its
            // in-memory cache stays stale even after we update the DB on disk.
            // Killing it causes launchd to auto-restart it; on startup it reads
            // the SQLite DB fresh and picks up our new entries.
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
            diag.append("posterboardd scan: pid=\(pbdPid)")
            if pbdPid > 0 {
                let kr = Darwin.kill(pbdPid, SIGTERM)
                let ke = Darwin.errno
                diag.append("kill(SIGTERM) rc=\(kr) errno=\(ke)")
                if kr == 0 { Thread.sleep(forTimeInterval: 0.8) }
            }

            // ── WallpaperKit probe: find reload API on PRBPosterExtensionDataStore ──
            dlopen("/System/Library/PrivateFrameworks/WallpaperKit.framework/WallpaperKit", RTLD_NOW)
            for className in ["PRBPosterExtensionDataStore", "PRBPosterDataStoreController",
                               "PRBCollectionsDataProvider", "PRBPosterDataManager"] {
                guard let cls = NSClassFromString(className) as? NSObject.Type else {
                    diag.append("WK \(className): absent"); continue
                }
                diag.append("WK found: \(className)")
                for sharedSel in ["sharedDataStore", "sharedInstance", "defaultDataStore", "sharedManager"] {
                    guard cls.responds(to: Selector(sharedSel)),
                          let inst = cls.perform(Selector(sharedSel))?.takeUnretainedValue() as? NSObject
                    else { continue }
                    diag.append("WK \(className) instance via \(sharedSel)")
                    for reloadSel in ["reload", "reloadData", "invalidateCache", "rebuildCollections",
                                      "reloadFromStorage", "reloadFromDisk", "forceRefresh", "resetCaches"] {
                        if inst.responds(to: Selector(reloadSel)) {
                            inst.perform(Selector(reloadSel))
                            diag.append("WK \(className) called \(reloadSel)")
                        }
                    }
                    break
                }
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
