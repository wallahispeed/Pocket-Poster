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
    /// Without this, PosterBoard ignores newly written descriptor folders until
    /// it performs its own async rescan (which may take several relaunches).
    static func writeToPosterBoardDB(appHash: String, entries: [(uuid: String, ext: String)]) {
        guard !entries.isEmpty else { return }

        let dbPath = BadQuery.applicationContainerPath(appHash: appHash)
            + "/Library/Application Support/PRBPosterExtensionDataStore/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
        let dbURL = URL(fileURLWithPath: dbPath)
        let dbDirPath = (dbPath as NSString).deletingLastPathComponent

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp_pb_\(UUID().uuidString).sqlite3")

        // Get sandbox extension for the DB's parent directory
        guard let dirHandle = try? BadQuery.consume(path: dbDirPath, create: true) else {
            print("writeToPosterBoardDB: cannot sandbox-extend DB dir — skipping")
            return
        }

        // Copy the DB to our temp directory
        // Clean container = no DB yet; PosterBoard will create and auto-scan on first launch
        guard FileManager.default.fileExists(atPath: dbPath),
              (try? FileManager.default.copyItem(at: dbURL, to: tempURL)) != nil else {
            dirHandle.release()
            print("writeToPosterBoardDB: DB not present (clean container) — PosterBoard will auto-scan")
            return
        }
        dirHandle.release()

        // Open and modify the temp copy with SQLite
        var db: OpaquePointer?
        guard sqlite3_open(tempURL.path, &db) == SQLITE_OK else {
            print("writeToPosterBoardDB: sqlite3_open failed")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        var stmt: OpaquePointer?

        // Get current poster sequence counter
        var seq: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT seq FROM sqlite_sequence WHERE name = 'poster'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            seq = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt); stmt = nil

        // Get current max roleSortKey for lock screen role
        var maxSortKey: Int64 = seq
        if sqlite3_prepare_v2(db, "SELECT MAX(roleSortKey) FROM posterRoleMembership WHERE roleId = 'PRPosterRoleLockScreen'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW,
           sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            maxSortKey = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt); stmt = nil

        let now = Date().timeIntervalSince1970
        for entry in entries {
            seq += 1
            maxSortKey += 1
            // Payload format matches Nugget's PRPosterRoleAttributeTypeUsageMetadata payload
            let payload = "{\"creationDate\":\(now),\"extensionAvailable\":true,\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\",\"lastActivatedDate\":\(now + 0.001),\"lastSelectedDate\":\(now + 0.0001)}"
            sqlite3_exec(db, "INSERT OR IGNORE INTO poster (posterId, UUID, providerId) VALUES (\(seq), '\(entry.uuid)', '\(entry.ext)')", nil, nil, nil)
            sqlite3_exec(db, "INSERT OR IGNORE INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) VALUES ('\(entry.uuid)', 'PRPosterRoleLockScreen', 'PRPosterRoleAttributeTypeUsageMetadata', '\(payload)')", nil, nil, nil)
            sqlite3_exec(db, "INSERT OR IGNORE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES ('\(entry.uuid)', 'PRPosterRoleLockScreen', \(maxSortKey))", nil, nil, nil)
        }
        sqlite3_exec(db, "UPDATE sqlite_sequence SET seq = \(seq) WHERE name = 'poster'", nil, nil, nil)
        sqlite3_close(db)

        // Write modified DB back to PosterBoard's container
        guard let writeHandle = try? BadQuery.consume(path: dbDirPath, create: true) else {
            print("writeToPosterBoardDB: cannot get write extension — DB changes lost")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        do {
            try FileManager.default.removeItem(at: dbURL)
            try FileManager.default.copyItem(at: tempURL, to: dbURL)
            // Remove WAL/SHM so PosterBoard reads our updated main DB on next launch
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath + "-shm"))
            print("writeToPosterBoardDB: registered \(entries.count) descriptor(s) in PosterBoard DB")
        } catch {
            print("writeToPosterBoardDB: write-back failed: \(error)")
        }
        writeHandle.release()
        try? FileManager.default.removeItem(at: tempURL)
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
