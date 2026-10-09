//  Inject13Diagnostics.swift — Pocket Poster
//  Full diagnostic sweep for inject13 chain debugging.
//  Writes report to Documents/inject13_diag.txt and returns the text.

import Foundation
import SQLite3
import UIKit

struct Inject13Diagnostics {

    static func run(appHash: String) -> String {
        var out: [String] = []
        let fm = FileManager.default
        func add(_ s: String) { out.append(s) }

        // ── 1. Environment ───────────────────────────────────────────────
        add("=== 1. ENVIRONMENT ===")
        add("date: \(Date())")
        add("iOS: \(UIDevice.current.systemVersion)")
        add("model: \(UIDevice.current.model)")
        add("extVer (hardcoded): \(SymHandler.getExtensionVersion())")
        add("bad_query available: \(BadQuery.isAvailable)")
        add("appHash: \(appHash.isEmpty ? "*** EMPTY — set it first ***" : appHash)")

        guard !appHash.isEmpty else {
            add("\nABORTED: no app hash")
            return finalize(out)
        }

        // ── 2. PRBPosterExtensionDataStore version discovery ─────────────
        add("\n=== 2. DATASTORE VERSION DISCOVERY ===")
        let containerBase = BadQuery.applicationContainerPath(appHash: appHash)
        let datastoreBase = "\(containerBase)/Library/Application Support/PRBPosterExtensionDataStore"
        let dsH = try? BadQuery.consume(path: datastoreBase, create: true); defer { dsH?.release() }
        add("containerBase: \(containerBase)")
        add("datastoreBase exists: \(fm.fileExists(atPath: datastoreBase))")
        let dsItems = (try? fm.contentsOfDirectory(atPath: datastoreBase)) ?? []
        add("datastoreBase items: \(dsItems.sorted().joined(separator: ", "))")
        let verDirs = dsItems.filter { $0.first?.isNumber == true }
        add("numeric version dirs: \(verDirs.sorted().joined(separator: ", ")) (hardcoded=\(SymHandler.getExtensionVersion()))")
        if !verDirs.contains(SymHandler.getExtensionVersion()) {
            add("⚠️  hardcoded version '\(SymHandler.getExtensionVersion())' NOT present — wrong version!")
        }

        // ── 3. Extensions root ───────────────────────────────────────────
        add("\n=== 3. EXTENSIONS ROOT ===")
        let ver = SymHandler.getExtensionVersion()
        let extensionsRoot = "\(datastoreBase)/\(ver)/Extensions"
        let extRH = try? BadQuery.consume(path: extensionsRoot, create: true); defer { extRH?.release() }
        add("path: \(extensionsRoot)")
        add("exists: \(fm.fileExists(atPath: extensionsRoot))")
        let extDirs = (try? fm.contentsOfDirectory(atPath: extensionsRoot)) ?? []
        add("extensions[\(extDirs.count)]:")
        extDirs.sorted().forEach { add("  \($0)") }

        // ── 4. Per-extension deep scan ───────────────────────────────────
        add("\n=== 4. EXTENSION DESCRIPTOR DEEP SCAN ===")
        for extName in extDirs.sorted() {
            add("\n  ▶ EXT: \(extName)")
            let descPath = "\(extensionsRoot)/\(extName)/descriptors"
            let dH = try? BadQuery.consume(path: descPath, create: true); defer { dH?.release() }
            let descExists = fm.fileExists(atPath: descPath)
            add("  descriptors/ exists: \(descExists)")
            guard descExists else { add("  (skipping)"); continue }

            let items = (try? fm.contentsOfDirectory(atPath: descPath)) ?? []
            add("  items[\(items.count)]: \(items.joined(separator: ", "))")

            // Collection.plist
            let collPath = "\(descPath)/Collection.plist"
            add("  Collection.plist exists: \(fm.fileExists(atPath: collPath))")
            if let cd = fm.contents(atPath: collPath),
               let c = try? PropertyListSerialization.propertyList(from: cd, options: [], format: nil) as? [String: Any] {
                add("  Collection.plist: \(c)")
            }

            // UUID folders
            let uuids = items.filter { !$0.hasPrefix(".") && $0 != "Collection.plist" }
            add("  UUID folders: \(uuids.count)")
            for uuid in uuids.prefix(2) {
                add("  ┌── \(uuid)")
                let up = "\(descPath)/\(uuid)"
                let uH = try? BadQuery.consume(path: up, create: true); defer { uH?.release() }
                let uFiles = (try? fm.contentsOfDirectory(atPath: up)) ?? []
                add("  │ files[\(uFiles.count)]: \(uFiles.sorted().joined(separator: ", "))")
                for fname in uFiles.sorted() {
                    let fp = "\(up)/\(fname)"
                    let fH = try? BadQuery.consume(path: fp, create: true); defer { fH?.release() }
                    let sz = (try? fm.attributesOfItem(atPath: fp))?[.size] as? Int ?? 0
                    if sz > 0 && sz <= 16384, let data = fm.contents(atPath: fp) {
                        if fname == "Wallpaper.plist",
                           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                            add("  │ Wallpaper.plist: family=\(plist["family"] ?? "nil")  id=\(plist["identifier"] ?? "nil")  ver=\(plist["version"] ?? "nil")")
                        } else if fname == "Collection.plist" || fname.hasSuffix(".plist"),
                                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                            add("  │ \(fname) [\(sz)B] plist: \(plist)")
                        } else if data.prefix(6) == Data("bplist".utf8) {
                            add("  │ \(fname) [\(sz)B] bplist/NSKeyedArchive")
                            // Extract $classname and string values from NSKeyedArchive
                            if let bpl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                               let objects = bpl["$objects"] as? [Any] {
                                for obj in objects.prefix(20) {
                                    if let d2 = obj as? [String: Any], let cn = d2["$classname"] as? String {
                                        add("  │   $classname: \(cn)")
                                    }
                                    if let s = obj as? String, !s.isEmpty && s != "$null" && s.count < 200 {
                                        add("  │   str: \(s)")
                                    }
                                }
                            }
                        } else if let str = String(data: data, encoding: .utf8) {
                            add("  │ \(fname) [\(sz)B] utf8: \(str.prefix(500))")
                        } else {
                            add("  │ \(fname) [\(sz)B] hex: \(data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
                        }
                    } else if sz > 16384 {
                        add("  │ \(fname) [\(sz)B] (too large to dump)")
                    } else {
                        add("  │ \(fname) [\(sz)B] (empty or unreadable)")
                    }
                }
                add("  └──")
            }
        }

        // ── 5. inject13_font.keyed survival check ─────────────────────────
        add("\n=== 5. INJECT13 FLAT FILE SURVIVAL ===")
        add("(Checking if the .keyed file we wrote survived the respring)")
        var foundKeyed = false
        for extName in extDirs {
            let descPath = "\(extensionsRoot)/\(extName)/descriptors"
            let ourFile = "\(descPath)/inject13_font.keyed"
            let fH2 = try? BadQuery.consume(path: ourFile, create: true); defer { fH2?.release() }
            if fm.fileExists(atPath: ourFile) {
                if let data = fm.contents(atPath: ourFile) {
                    add("FOUND: \(ourFile) (\(data.count)B) — posterboardd did NOT wipe it")
                } else {
                    add("FOUND but unreadable: \(ourFile)")
                }
                foundKeyed = true
            }
        }
        if !foundKeyed {
            add("NOT FOUND in any extension — posterboardd likely wiped it on restart (confirms it scanned the dir)")
        }

        // ── 6. SQLite DB ───────────────────────────────────────────────────
        add("\n=== 6. SQLITE DB ===")
        let dbPath = "\(datastoreBase)/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
        let dbH = try? BadQuery.consume(path: dbPath, create: true); defer { dbH?.release() }
        add("db exists: \(fm.fileExists(atPath: dbPath))")
        add("wal exists: \(fm.fileExists(atPath: dbPath + "-wal"))")
        add("shm exists: \(fm.fileExists(atPath: dbPath + "-shm"))")
        if fm.fileExists(atPath: dbPath) {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
            add("sqlite3_open rc: \(rc) (\(rc == 0 ? "OK" : "FAIL"))")
            if rc == SQLITE_OK, let db = db {
                // Tables
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK {
                    var tables: [String] = []
                    while sqlite3_step(stmt) == SQLITE_ROW { tables.append(String(cString: sqlite3_column_text(stmt, 0))) }
                    add("tables: \(tables.joined(separator: ", "))")
                    sqlite3_finalize(stmt); stmt = nil
                }
                // poster rows
                if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM poster", -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW { add("poster row count: \(sqlite3_column_int64(stmt, 0))") }
                    sqlite3_finalize(stmt); stmt = nil
                }
                if sqlite3_prepare_v2(db, "SELECT posterId, substr(UUID,1,8), providerId FROM poster ORDER BY posterId DESC LIMIT 20", -1, &stmt, nil) == SQLITE_OK {
                    add("poster rows (newest 20):")
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let pid = sqlite3_column_int64(stmt, 0)
                        let uuid = String(cString: sqlite3_column_text(stmt, 1))
                        let prov = String(cString: sqlite3_column_text(stmt, 2))
                        add("  pid=\(pid) uuid=\(uuid)… prov=\(prov)")
                    }
                    sqlite3_finalize(stmt); stmt = nil
                }
                // All distinct providerIds
                if sqlite3_prepare_v2(db, "SELECT DISTINCT providerId FROM poster", -1, &stmt, nil) == SQLITE_OK {
                    var provs: [String] = []
                    while sqlite3_step(stmt) == SQLITE_ROW { provs.append(String(cString: sqlite3_column_text(stmt, 0))) }
                    add("distinct providerIds: \(provs.joined(separator: "\n  "))")
                    sqlite3_finalize(stmt); stmt = nil
                }
                sqlite3_close(db)
            } else {
                if let db = db { sqlite3_close(db) }
            }
        }

        // ── 7. NSKeyedArchive payload validation ───────────────────────────
        add("\n=== 7. NSKEYED ARCHIVE VALIDATION ===")
        do {
            let data = try Inject13.buildPayload()
            add("buildPayload: OK (\(data.count) bytes)")
            add("starts bplist00: \(data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
            if let bpl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let objects = bpl["$objects"] as? [Any] {
                    var classNames: [String] = []
                    var classHierarchies: [[String]] = []
                    var stringVals: [String] = []
                    for obj in objects {
                        if let d2 = obj as? [String: Any] {
                            if let cn = d2["$classname"] as? String { classNames.append(cn) }
                            if let ch = d2["$classes"] as? [String] { classHierarchies.append(ch) }
                        } else if let s = obj as? String, !s.isEmpty && s != "$null" {
                            stringVals.append(s)
                        }
                    }
                    add("$classnames in archive: \(classNames.joined(separator: ", "))")
                    add("$classes hierarchies: \(classHierarchies.map { $0.joined(separator: "→") }.joined(separator: " | "))")
                    add("string values: \(stringVals.joined(separator: " | "))")
                    let hasCorrectClass = classNames.contains("PRPosterCustomTimeFontConfiguration")
                    add(hasCorrectClass ? "✓ correct $classname present" : "✗ PRPosterCustomTimeFontConfiguration NOT in archive")
                    let hasFilePath = stringVals.contains(Inject13.testTraversalPath)
                    add(hasFilePath ? "✓ traversal path present in archive" : "✗ traversal path NOT in archive strings")
                    let hasPSName = stringVals.contains(Inject13.testPSName)
                    add(hasPSName ? "✓ PSName '\(Inject13.testPSName)' present" : "✗ PSName NOT in archive")
                }
            }
        } catch {
            add("buildPayload FAILED: \(error)")
        }

        // ── 8. Traversal math & target file check ──────────────────────────
        add("\n=== 8. PATH TRAVERSAL VERIFICATION ===")
        let clockFaceBase = "/System/Applications/MobileTimer.app/PlugIns/ClockFace.appex"
        add("ClockFace.appex exists: \(fm.fileExists(atPath: clockFaceBase))")
        if fm.fileExists(atPath: clockFaceBase) {
            let cfFiles = (try? fm.contentsOfDirectory(atPath: clockFaceBase)) ?? []
            add("ClockFace.appex contents: \(cfFiles.sorted().joined(separator: ", "))")
        }
        // Manually compute URL traversal
        let baseURL = URL(fileURLWithPath: clockFaceBase).appendingPathComponent("dummy")
        // URLByAppendingPathComponent strips last component, so base is the dir itself
        let baseDir = URL(fileURLWithPath: clockFaceBase + "/")
        let traversed = URL(string: "../../../../Library/Fonts/MarkerFelt.ttc", relativeTo: baseDir)?.standardized
        add("traversal baseDir: \(clockFaceBase)/")
        add("traversal path: ../../../../Library/Fonts/MarkerFelt.ttc")
        add("traversal result: \(traversed?.path ?? "nil")")
        let targetPath = traversed?.path ?? "/System/Library/Fonts/MarkerFelt.ttc"
        add("target exists: \(fm.fileExists(atPath: targetPath))")
        // Check alternate traversal counts
        for count in [3, 4, 5] {
            let rel = String(repeating: "../", count: count) + "Library/Fonts/MarkerFelt.ttc"
            let url = URL(string: rel, relativeTo: baseDir)?.standardized
            add("  \(count)x../: \(url?.path ?? "nil") exists=\(url.map { fm.fileExists(atPath: $0.path) } ?? false)")
        }
        // List available system fonts (so we can pick a different test target)
        let fontsDir = "/System/Library/Fonts"
        if let fonts = try? fm.contentsOfDirectory(atPath: fontsDir) {
            add("System fonts available: \(fonts.sorted().prefix(20).joined(separator: ", "))")
        }
        // iOS 26 may use /System/cryptexes/OS/System/Library/Fonts
        let cryptexFonts = "/System/cryptexes/OS/System/Library/Fonts"
        add("cryptexes fonts dir exists: \(fm.fileExists(atPath: cryptexFonts))")
        if fm.fileExists(atPath: cryptexFonts) {
            let cf2 = (try? fm.contentsOfDirectory(atPath: cryptexFonts)) ?? []
            add("cryptexes fonts: \(cf2.sorted().prefix(10).joined(separator: ", "))")
        }

        // ── 9. Clock-related extension names ──────────────────────────────
        add("\n=== 9. CLOCK POSTER EXTENSION IDENTIFICATION ===")
        let clockKeywords = ["clock", "timer", "mobiletimer", "postertime", "clockface", "digital", "analog"]
        let clockExts = extDirs.filter { e in clockKeywords.contains { e.lowercased().contains($0) } }
        if clockExts.isEmpty {
            add("No clock-related extension found among: \(extDirs.sorted().joined(separator: ", "))")
            add("PROBLEM: If there's no clock extension entry, posterboardd has never saved a ClockPoster on this device,")
            add("         OR the ClockPoster uses a different descriptor path (not under Extensions/).")
        } else {
            add("Clock-related extensions: \(clockExts.joined(separator: ", "))")
        }
        // Also look for anything with "WallpaperKit" as that's what collectionsposter uses
        let wpkitExts = extDirs.filter { $0.contains("WallpaperKit") }
        add("WallpaperKit extensions: \(wpkitExts.isEmpty ? "(none)" : wpkitExts.joined(separator: ", "))")

        // ── 10. bad_query token test ───────────────────────────────────────
        add("\n=== 10. BAD_QUERY TOKEN TEST ===")
        let testPaths = [
            extensionsRoot,
            datastoreBase,
            dbPath,
        ]
        for tp in testPaths {
            do {
                let h = try BadQuery.consume(path: tp, create: true)
                h.release()
                add("  ✓ token OK: \(tp)")
            } catch {
                add("  ✗ token FAILED (\(error)): \(tp)")
            }
        }

        // ── 11. Actual write test ──────────────────────────────────────────
        add("\n=== 11. WRITE TEST (NEW FORMAT) ===")
        add("Testing UUID-folder descriptor structure write (does NOT trigger posterboardd yet):")
        do {
            let testExtName = extDirs.first ?? "com.apple.WallpaperKit.CollectionsPoster"
            let testDescPath = "\(extensionsRoot)/\(testExtName)/descriptors"
            let testUUID = "INJECT13-TEST-\(UUID().uuidString)"
            let testUUIDPath = "\(testDescPath)/\(testUUID)"

            let hDesc = try BadQuery.consume(path: testDescPath, create: true)
            defer { hDesc.release() }
            try fm.createDirectory(atPath: testUUIDPath, withIntermediateDirectories: true)
            let hUUID = try BadQuery.consume(path: testUUIDPath, create: true)
            defer { hUUID.release() }
            // Write a test file
            let testData = "inject13-test".data(using: .utf8)!
            try testData.write(to: URL(fileURLWithPath: "\(testUUIDPath)/test.txt"))
            add("  ✓ created UUID folder: \(testUUIDPath)")
            add("  ✓ wrote test.txt inside it")
            // Clean up
            try? fm.removeItem(atPath: testUUIDPath)
            add("  ✓ cleanup OK")
        } catch {
            add("  ✗ write test FAILED: \(error)")
        }

        return finalize(out)
    }

    private static func finalize(_ out: [String]) -> String {
        let text = out.joined(separator: "\n")
        // Save to Documents
        let docsDir = SymHandler.getDocumentsDirectory()
        let outPath = docsDir.appendingPathComponent("inject13_diag.txt")
        try? text.write(to: outPath, atomically: true, encoding: .utf8)
        return text
    }
}
