//
//  PosterBoardManager.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import ZIPFoundation
import UIKit

class PosterBoardManager: ObservableObject {
    static let ShortcutURL = "https://www.icloud.com/shortcuts/a28d2c02ca11453cb5b8f91c12cfa692"
    static let WallpapersURL = "https://cowabun.ga/wallpapers"

    static let MaxTendies = 10

    static let shared = PosterBoardManager()

    @Published var selectedTendies: [URL] = []
    @Published var videos: [LoadInfo] = []

    func getTendiesStoreURL() -> URL {
        let tendiesStoreURL = SymHandler.getDocumentsDirectory().appendingPathComponent("KFC Bucket", conformingTo: .directory)
        // create it if it doesn't exist
        if !FileManager.default.fileExists(atPath: tendiesStoreURL.path()) {
            try? FileManager.default.createDirectory(at: tendiesStoreURL, withIntermediateDirectories: true)
        }
        return tendiesStoreURL
    }

    func setSystemLanguage(to new_lang: String) -> Bool {
        // Load Preferences private frameworks if needed
        dlopen("/System/Library/PrivateFrameworks/SettingsFoundation.framework/SettingsFoundation", RTLD_NOW)
        dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW)
        dlopen("/System/Library/PrivateFrameworks/InternationalSupport.framework/InternationalSupport", RTLD_NOW)

        var langManager: NSObject = NSObject()
        if #available(iOS 18.0, *) {
            guard let obj = objc_getClass("IPSettingsUtilities") as? NSObject else { return false }
            langManager = obj
        } else {
            guard let obj = objc_getClass("PSLanguageSelector") as? NSObject else { return false }
            langManager = obj
        }

        if let success = langManager.perform(Selector(("setLanguage:")), with: new_lang) {
            return success != nil
        }

        return false
    }

    /// Wipe PosterBoard custom descriptor collections using bad_query (real delete).
    /// Falls back to language-toggle trick on older exploit path.
    func resetCollections(appHash: String) throws {
        if SymHandler.prefersBadQuery {
            try wipeDescriptorsViaBadQuery(appHash: appHash)
            return
        }

        // Legacy: language toggle forces PosterBoard to rebuild collections
        guard let lang = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first else {
            throw ApplyError.unexpected(info: "Could not read system language for reset.")
        }
        guard setSystemLanguage(to: lang) else {
            throw ApplyError.unexpected(info: "Language API failed. Reset collections manually in Settings → Language & Region.")
        }
    }

    /// Delete everything under each PRBPosterExtensionDataStore/*/Extensions/*/descriptors.
    private func wipeDescriptorsViaBadQuery(appHash: String) throws {
        let ver = SymHandler.getExtensionVersion()
        let extensionsRoot = BadQuery.applicationContainerPath(appHash: appHash)
            + "/Library/Application Support/PRBPosterExtensionDataStore/\(ver)/Extensions"

        // Open parent with sandbox extension
        let rootHandle = try BadQuery.consume(path: extensionsRoot, create: true)
        defer { rootHandle.release() }

        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionsRoot) else {
            // Nothing to wipe — treat as success (collections already empty / never set up)
            return
        }

        let extDirs = try fm.contentsOfDirectory(atPath: extensionsRoot)
        var wiped = 0
        for extName in extDirs {
            let descriptorsPath = (extensionsRoot as NSString)
                .appendingPathComponent(extName)
                .appending("/descriptors")

            // Ensure we hold an extension on the descriptors dir itself
            let descHandle = try? BadQuery.consume(path: descriptorsPath, create: true)
            defer { descHandle?.release() }

            guard fm.fileExists(atPath: descriptorsPath) else { continue }

            let items = (try? fm.contentsOfDirectory(atPath: descriptorsPath)) ?? []
            for item in items {
                if item == "__MACOSX" || item.hasPrefix(".") { continue }
                let full = (descriptorsPath as NSString).appendingPathComponent(item)
                try? fm.removeItem(atPath: full)
                wiped += 1
            }
        }
        print("resetCollections: wiped \(wiped) descriptor item(s)")
    }

    func openPosterBoard() -> Bool {
        guard let obj = objc_getClass("LSApplicationWorkspace") as? NSObject else { return false }
        let workspace = obj.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() as? NSObject

        if let success = workspace?.perform(Selector(("openApplicationWithBundleID:")), with: "com.apple.PosterBoard") {
            return success != nil
        }

        return false
    }

    private func unzipFile(at url: URL) throws -> URL {
        let fileName = url.deletingPathExtension().lastPathComponent
        // Replace spaces and %20 with underscores
        let normalizedFileName = fileName.replacingOccurrences(of: "[ \\%20]", with: "_", options: .regularExpression)
        let fileData = try Data(contentsOf: url)
        let fileManager = FileManager()

        // Write the file to the Documents Directory
        let path = SymHandler.getDocumentsDirectory().appendingPathComponent("UnzipItems", conformingTo: .directory).appendingPathComponent(UUID().uuidString)
        if !FileManager.default.fileExists(atPath: path.path()) {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }

        // Remove All files in this directory
        let existingFiles = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        for fileUrl in existingFiles
        {
            try FileManager.default.removeItem(at: fileUrl)
        }
        let zipURL = path.appending(path: normalizedFileName)

        // Save our Zip file
        try fileData.write(to: zipURL, options: [.atomic])

        // Unzip the Zipped Up File
        var destinationURL = path
        if FileManager.default.fileExists(atPath: zipURL.path())
        {
            destinationURL.append(path: "directory")
            try fileManager.unzipItem(at: zipURL, to: destinationURL)
        }

        return destinationURL
    }

    func runShortcut(named name: String) {
        guard let urlEncodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(name)") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func getDescriptorsFromTendie(_ url: URL) throws -> [String: [URL]]? {
        for dir in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let fileName = dir.lastPathComponent
            if fileName.lowercased() == "container" {
                // container support, find the extensions
                let extDir = dir.appending(path: "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions")
                var retList: [String: [URL]] = [:]
                for ext in try FileManager.default.contentsOfDirectory(at: extDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    let descrDir = ext.appendingPathComponent("descriptors")
                    retList[ext.lastPathComponent] = [descrDir]
                }
                return retList
            }
            else if fileName.lowercased() == "descriptor" || fileName.lowercased() == "descriptors" || fileName.lowercased() == "ordered-descriptor" || fileName.lowercased() == "ordered-descriptors" { // TODO: Add ordered descriptors
                return ["com.apple.WallpaperKit.CollectionsPoster": [dir]]
            }
            else if fileName.lowercased() == "video-descriptor" || fileName.lowercased() == "video-descriptors" {
                return ["com.apple.PhotosUIPrivate.PhotosPosterProvider": [dir]]
            }
        }
        // TODO: Add error handling here
        return nil
    }

    func randomizeWallpaperId(url: URL) throws {
        let randomizedID = Int.random(in: 9999...99999)
        var files = [URL]()
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator
            {
                do
                {
                    let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
                    if fileAttributes.isRegularFile!
                    {
                        files.append(fileURL)
                    }
                }
                catch
                {
                    print(error, fileURL)
                }
            }
        }

        func setPlistValue(file: String, key: String, value: Any, recursive: Bool = true) {
            // thanks gpt
            guard let plistData = FileManager.default.contents(atPath: file),
                  var plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                return
            }

            plist[key] = value

            guard let updatedData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
                return
            }

            do {
                try updatedData.write(to: URL(fileURLWithPath: file))
            } catch {
                print("Failed to write updated plist: \(error)")
            }
        }

        for file in files {
            switch file.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try String(randomizedID).data(using: .utf8)?.write(to: file)

            case "com.apple.posterkit.provider.contents.userInfo":
                setPlistValue(file: file.path(), key: "wallpaperRepresentingIdentifier", value: randomizedID)

            case "Wallpaper.plist":
                setPlistValue(file: file.path(), key: "identifier", value: randomizedID, recursive: false)

            default:
                continue
            }
        }
    }

    func applyTendies(appHash: String) throws {
        // organize the descriptors into their respective extensions
        var extList: [String: [URL]] = [:]
        // create the video first
        if videos.count > 0 {
            extList["com.apple.WallpaperKit.CollectionsPoster"] = []
            for video in videos {
                switch video.loadState {
                case .loaded(let movie):
                    do {
                        let newVideo = try VideoHandler.createCaml(from: movie.url, autoReverses: video.autoReverses)
                        extList["com.apple.WallpaperKit.CollectionsPoster"]?.append(newVideo)
                    } catch {
                        print(error.localizedDescription)
                    }
                default:
                    print("Video not loaded!")
                }
            }
        }
        UIApplication.shared.change(title: NSLocalizedString("Applying Wallpapers...", comment: ""), body: NSLocalizedString("Extracting tendies...", comment: "happens when unzipping the files"))
        for url in selectedTendies {
            let unzippedDir = try unzipFile(at: url)
            guard let descriptors = try getDescriptorsFromTendie(unzippedDir) else { continue } // TODO: Add error handling
            extList.merge(descriptors) { (first, second) in first + second }
        }

        defer {
            SymHandler.cleanup()
        }

        let useBadQuery = SymHandler.prefersBadQuery
        if useBadQuery {
            UIApplication.shared.change(title: NSLocalizedString("Applying Wallpapers...", comment: ""), body: "bad_query sandbox escape…")
        }

        // Accumulate written UUID→ext pairs for SQLite DB registration
        var allDBEntries: [(uuid: String, ext: String)] = []

        for (ext, descriptorsList) in extList {
            var foldersToWrite: [URL] = []
            for descriptors in descriptorsList {
                for descr in try FileManager.default.contentsOfDirectory(at: descriptors, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    if descr.lastPathComponent != "__MACOSX" {
                        try randomizeWallpaperId(url: descr)
                        foldersToWrite.append(descr)
                    }
                }
            }

            if useBadQuery {
                // Wipe stale UUID descriptor folders for this extension so they don't
                // accumulate across Apply attempts and confuse PosterBoard's scanner.
                let descPath = BadQuery.descriptorsPath(appHash: appHash, ext: ext)
                if let wH = try? BadQuery.consume(path: descPath, create: true) {
                    defer { wH.release() }
                    let old = (try? FileManager.default.contentsOfDirectory(atPath: descPath)) ?? []
                    for item in old where !item.hasPrefix(".") {
                        try? FileManager.default.removeItem(atPath: descPath + "/" + item)
                    }
                }
                // iOS 26/27: direct write via container_query sandbox extension
                do {
                    let uuids = try SymHandler.writeDescriptorsViaBadQuery(appHash: appHash, ext: ext, descriptorFolders: foldersToWrite)
                    for uuid in uuids { allDBEntries.append((uuid: uuid, ext: ext)) }
                } catch {
                    // Fall back to legacy .Trash symlink if bad_query path fails
                    print("bad_query apply failed, falling back to symlink: \(error)")
                    try applyDescriptorsViaSymlink(appHash: appHash, ext: ext, folders: foldersToWrite)
                }
            } else {
                try applyDescriptorsViaSymlink(appHash: appHash, ext: ext, folders: foldersToWrite)
            }
            SymHandler.cleanup()
        }

        // Register all written descriptors in PosterBoard's SQLite database.
        // PosterBoard reads this DB on launch to populate the collections picker —
        // without these rows, the new wallpaper won't appear until PosterBoard
        // rescans on its own (which can take several relaunches).
        if useBadQuery {
            SymHandler.writeToPosterBoardDB(appHash: appHash, entries: allDBEntries)
        }

        // clean up all possible files
        for url in selectedTendies {
            try? FileManager.default.removeItem(at: SymHandler.getDocumentsDirectory().appendingPathComponent("UnzipItems", conformingTo: .directory))
            try? FileManager.default.removeItem(at: SymHandler.getDocumentsDirectory().appendingPathComponent(url.lastPathComponent))
            try? FileManager.default.removeItem(at: SymHandler.getDocumentsDirectory().appendingPathComponent(url.deletingPathExtension().lastPathComponent))
        }
    }

    /// Legacy exploit: symlink Documents/.Trash → descriptors, then trashItem into it.
    private func applyDescriptorsViaSymlink(appHash: String, ext: String, folders: [URL]) throws {
        let _ = try SymHandler.createDescriptorsSymlink(appHash: appHash, ext: ext)
        for descr in folders {
            let newURL = SymHandler.getDocumentsDirectory().appendingPathComponent(UUID().uuidString, conformingTo: .directory)
            try FileManager.default.copyItem(at: descr, to: newURL)
            try FileManager.default.trashItem(at: newURL, resultingItemURL: nil)
        }
    }

    static func clearCache() throws {
        SymHandler.cleanup()
        let docDir = SymHandler.getDocumentsDirectory()
        for file in try FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
            if file.lastPathComponent != "CarPlayPhotos" {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
