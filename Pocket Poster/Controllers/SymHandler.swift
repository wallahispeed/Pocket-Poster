//
//  SymHandler.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import SQLite3

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
    /// Strategy: the file-level bad_query extension grants read-only access to
    /// existing files (sqlite3_open with READWRITE → SQLITE_CANTOPEN=14). So we:
    ///   1. Copy PosterBoard's DB (and WAL) into our own container using the
    ///      read-only file extension — no sandbox restriction on reading.
    ///   2. Open our copy with full read-write access and insert our rows.
    ///   3. Checkpoint our copy so all changes land in the main DB file.
    ///   4. Use a directory extension (which DOES grant write/create) to replace
    ///      PosterBoard's main DB, WAL, and SHM with our modified copy.
    /// This mirrors how Nugget modifies the DB on PC, done on-device instead.
    static func writeToPosterBoardDB(appHash: String, entries: [(uuid: String, ext: String)]) {
        guard !entries.isEmpty else { return }

        let dbPath = BadQuery.applicationContainerPath(appHash: appHash)
            + "/Library/Application Support/PRBPosterExtensionDataStore/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let dbDir   = (dbPath as NSString).deletingLastPathComponent

        let tmpDBPath  = getLCDocumentsDirectory().appendingPathComponent("pp_pb_db.sqlite3").path
        let tmpWALPath = tmpDBPath + "-wal"

        var diag: [String] = ["appHash=\(appHash) entries=\(entries.count)"]
        defer {
            let text = diag.joined(separator: "\n")
            try? text.write(to: getLCDocumentsDirectory().appendingPathComponent("pp_db_diag.txt"),
                            atomically: true, encoding: .utf8)
        }

        let fm = FileManager.default

        // Clean up any leftover temp files from a prior run.
        try? fm.removeItem(atPath: tmpDBPath)
        try? fm.removeItem(atPath: tmpWALPath)

        // --- 1. Read PosterBoard's DB into our container ---
        // File extension grants stat + read but NOT write (rc=14 on open READWRITE).
        guard let dbReadHandle = try? BadQuery.consume(path: dbPath, create: true) else {
            diag.append("FAIL consume DB file"); return
        }
        diag.append("OK consume DB file")

        guard fm.fileExists(atPath: dbPath) else {
            dbReadHandle.release()
            diag.append("FAIL DB not found"); return
        }
        diag.append("OK DB exists")

        do {
            try fm.copyItem(atPath: dbPath, toPath: tmpDBPath)
            diag.append("OK copy main DB")
        } catch {
            dbReadHandle.release()
            diag.append("FAIL copy main DB: \(error)"); return
        }
        dbReadHandle.release()

        // Also copy WAL so our SQLite session sees committed-but-uncheckpointed data.
        let walReadHandle = try? BadQuery.consume(path: walPath, create: true)
        if fm.fileExists(atPath: walPath) {
            try? fm.copyItem(atPath: walPath, toPath: tmpWALPath)
            diag.append("WAL copied: \(fm.fileExists(atPath: tmpWALPath))")
        } else {
            diag.append("no WAL present")
        }
        walReadHandle?.release()

        // --- 2. Open our copy and insert rows ---
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(tmpDBPath, &db, SQLITE_OPEN_READWRITE, nil)
        diag.append("open copy rc=\(openRC)")
        guard openRC == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 3000)

        // Apply any WAL transactions so we see the full current state.
        let ckRC1 = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        diag.append("checkpoint(pre) rc=\(ckRC1)")

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW,
           let mode = sqlite3_column_text(stmt, 0) { diag.append("journal_mode=\(String(cString: mode))") }
        sqlite3_finalize(stmt); stmt = nil

        var seq: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT MAX(posterId) FROM poster", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW,
           sqlite3_column_type(stmt, 0) != SQLITE_NULL { seq = sqlite3_column_int64(stmt, 0) }
        sqlite3_finalize(stmt); stmt = nil
        diag.append("max posterId=\(seq)")

        var maxSortKey: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT MAX(roleSortKey) FROM posterRoleMembership WHERE roleId='PRPosterRoleLockScreen'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW,
           sqlite3_column_type(stmt, 0) != SQLITE_NULL { maxSortKey = sqlite3_column_int64(stmt, 0) }
        sqlite3_finalize(stmt); stmt = nil
        diag.append("max sortKey=\(maxSortKey)")

        let now = Date().timeIntervalSince1970
        var successCount = 0
        for entry in entries {
            seq += 1; maxSortKey += 1
            let payload = "{\"creationDate\":\(now),\"extensionAvailable\":true,\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\",\"lastActivatedDate\":\(now + 0.001),\"lastSelectedDate\":\(now + 0.0001)}"
            let rc1 = sqlite3_exec(db, "INSERT OR IGNORE INTO poster (posterId, UUID, providerId) VALUES (\(seq), '\(entry.uuid)', '\(entry.ext)')", nil, nil, nil)
            let rc2 = sqlite3_exec(db, "INSERT OR IGNORE INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) VALUES ('\(entry.uuid)', 'PRPosterRoleLockScreen', 'PRPosterRoleAttributeTypeUsageMetadata', '\(payload)')", nil, nil, nil)
            let rc3 = sqlite3_exec(db, "INSERT OR IGNORE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES ('\(entry.uuid)', 'PRPosterRoleLockScreen', \(maxSortKey))", nil, nil, nil)
            diag.append("entry \(entry.uuid.prefix(8))... poster=\(rc1) attrs=\(rc2) role=\(rc3)")
            if rc1 == SQLITE_OK && rc2 == SQLITE_OK && rc3 == SQLITE_OK { successCount += 1 }
        }
        diag.append("inserted \(successCount)/\(entries.count)")

        // Flush our changes out of WAL into the main DB file before we copy it back.
        let ckRC2 = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        diag.append("checkpoint(post) rc=\(ckRC2)")
        sqlite3_close(db); db = nil  // close before replacing in PosterBoard's dir

        // --- 3. Replace PosterBoard's DB with our modified copy ---
        // Directory extension grants write/create/delete within the dir.
        guard let dirHandle = try? BadQuery.consume(path: dbDir, create: true) else {
            diag.append("FAIL consume dbDir"); return
        }
        defer { dirHandle.release() }

        // Unlink stale WAL/SHM (they belonged to the old inode; PosterBoard will
        // create fresh ones after respring when it opens our new main DB file).
        try? fm.removeItem(atPath: walPath)
        try? fm.removeItem(atPath: shmPath)
        try? fm.removeItem(atPath: dbPath)

        do {
            try fm.copyItem(atPath: tmpDBPath, toPath: dbPath)
            diag.append("OK copy back → DB replaced")
        } catch {
            diag.append("FAIL copy back: \(error)")
        }

        try? fm.removeItem(atPath: tmpDBPath)
        try? fm.removeItem(atPath: tmpWALPath)

        print("writeToPosterBoardDB: wrote \(successCount)/\(entries.count) entry/entries to PosterBoard DB")
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
