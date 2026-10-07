//
//  PhysicsWallpaperGenerator.swift
//  Pocket Poster
//

import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import UIKit

enum PhysicsWallpaperGenerator {

    // MARK: - Public

    /// Render physics frames, encode video, build CAML descriptor, apply via bad_query.
    /// Call on a background thread. `onChange` fires on main thread.
    static func apply(appHash: String, onChange: @escaping (String) -> Void) throws {
        DispatchQueue.main.async { onChange("Rendering physics frames (0%)…") }

        let videoURL = try renderVideo(onChange: onChange)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Building CAML descriptor…") }
        let descriptorURL = try VideoHandler.createCaml(from: videoURL, autoReverses: true)

        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Applying descriptor…") }
        try applyDescriptor(appHash: appHash, descriptorURL: descriptorURL)

        // Option 2: scan InternalDaemon containers and attempt to write
        // wantsLiveScene = YES into SpringBoard/homeboardd's widget descriptor store.
        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Activating live scene…") }
        LiveWidgetActivator.activate()
        LiveWidgetActivator.postReloadNotifications()

        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Done — respinging…") }
    }

    // MARK: - Video rendering (manual physics + Core Graphics — no SKRenderer/Metal dependency)

    private static func renderVideo(onChange: @escaping (String) -> Void) throws -> URL {
        let fps: Double = 30
        let duration: Double = 8
        let totalFrames = Int(fps * duration)   // 240
        let dt: CGFloat = CGFloat(1.0 / fps)

        // iPhone 16 Pro logical-point resolution
        let w = 393
        let h = 852

        // ── Ball physics state ──────────────────────────────────────────
        let count = 40
        let radius: CGFloat = 16
        let gravityY: CGFloat = -400   // pts/s² — visually satisfying on 852pt screen
        let restitution: CGFloat = 0.75

        let colors: [UIColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .cyan, .systemBlue, .systemIndigo, .systemPurple,
            .systemPink, .white
        ]
        let cgColors = colors.map { $0.cgColor }

        var posX = [CGFloat](repeating: 0, count: count)
        var posY = [CGFloat](repeating: 0, count: count)
        var velX = [CGFloat](repeating: 0, count: count)
        var velY = [CGFloat](repeating: 0, count: count)

        for i in 0..<count {
            posX[i] = radius + CGFloat(i) / CGFloat(count) * (CGFloat(w) - 2 * radius)
            posY[i] = CGFloat.random(in: 150...700)
            velX[i] = CGFloat.random(in: -200...200)
            velY[i] = CGFloat.random(in: -50...150)
        }

        // ── AVAssetWriter ───────────────────────────────────────────────
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("physics_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: videoURL)

        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h
        ])
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h
            ])

        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        // ── Render loop ─────────────────────────────────────────────────
        for f in 0..<totalFrames {
            // Step physics — skip on frame 0 (render initial state first)
            if f > 0 {
                for i in 0..<count {
                    velY[i] += gravityY * dt
                    posX[i] += velX[i] * dt
                    posY[i] += velY[i] * dt

                    // Left/right walls
                    if posX[i] - radius < 0 {
                        posX[i] = radius
                        velX[i] = abs(velX[i]) * restitution
                    } else if posX[i] + radius > CGFloat(w) {
                        posX[i] = CGFloat(w) - radius
                        velX[i] = -abs(velX[i]) * restitution
                    }
                    // Floor (posY=0 is bottom in SpriteKit-style coords) / ceiling
                    if posY[i] - radius < 0 {
                        posY[i] = radius
                        velY[i] = abs(velY[i]) * restitution
                    } else if posY[i] + radius > CGFloat(h) {
                        posY[i] = CGFloat(h) - radius
                        velY[i] = -abs(velY[i]) * restitution
                    }
                }
            }

            // Draw frame into CVPixelBuffer via Core Graphics
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb = pb else { continue }

            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb),
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                // Black background
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

                // Draw balls — Core Graphics origin is top-left, our physics is y-up
                for i in 0..<count {
                    let cgY = CGFloat(h) - posY[i]   // flip y
                    ctx.setFillColor(cgColors[i % cgColors.count])
                    ctx.fillEllipse(in: CGRect(
                        x: posX[i] - radius, y: cgY - radius,
                        width: radius * 2, height: radius * 2
                    ))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
            while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            adaptor.append(pb, withPresentationTime: pts)

            if f % 15 == 0 {
                let pct = Int(Double(f + 1) / Double(totalFrames) * 100)
                DispatchQueue.main.async {
                    UIApplication.shared.change(title: "Physics Wallpaper",
                                                body: "Rendering frames (\(pct)%)…")
                }
            }
        }

        videoInput.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "PhysicsWallpaper", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Video encoding failed"])
        }
        return videoURL
    }

    // MARK: - Descriptor application

    private static func applyDescriptor(appHash: String, descriptorURL: URL) throws {
        let ext = "com.apple.WallpaperKit.CollectionsPoster"

        // createCaml returns a parent directory; enumerate to get the actual descriptor folder(s)
        let foldersToWrite = try FileManager.default.contentsOfDirectory(
            at: descriptorURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.lastPathComponent != "__MACOSX" }

        guard !foldersToWrite.isEmpty else {
            throw NSError(domain: "PhysicsWallpaper", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Descriptor directory is empty after createCaml"])
        }

        // Patch each descriptor's Wallpaper.plist to enable device-motion parallax
        for folder in foldersToWrite {
            let wallpaperPlist = folder.appendingPathComponent("Wallpaper.plist")
            if var dict = (NSDictionary(contentsOf: wallpaperPlist) as? [String: Any]) {
                dict["wantsDeviceMotion"] = true
                (dict as NSDictionary).write(to: wallpaperPlist, atomically: true)
            }
        }

        if SymHandler.prefersBadQuery {
            // Wipe stale physics descriptors so they don't accumulate across runs
            let descPath = BadQuery.descriptorsPath(appHash: appHash, ext: ext)
            if let wH = try? BadQuery.consume(path: descPath, create: true) {
                defer { wH.release() }
                let old = (try? FileManager.default.contentsOfDirectory(atPath: descPath)) ?? []
                for item in old where !item.hasPrefix(".") {
                    try? FileManager.default.removeItem(atPath: descPath + "/" + item)
                }
            }
            let uuids = try SymHandler.writeDescriptorsViaBadQuery(
                appHash: appHash, ext: ext, descriptorFolders: foldersToWrite)
            SymHandler.writeToPosterBoardDB(appHash: appHash,
                                             entries: uuids.map { (uuid: $0, ext: ext) })
        } else {
            _ = try SymHandler.createDescriptorsSymlink(appHash: appHash, ext: ext)
            let dst = SymHandler.getDocumentsDirectory()
                .appendingPathComponent(UUID().uuidString, conformingTo: .directory)
            for folder in foldersToWrite {
                try FileManager.default.copyItem(at: folder,
                    to: dst.appendingPathComponent(folder.lastPathComponent))
            }
            try FileManager.default.trashItem(at: dst, resultingItemURL: nil)
        }
        SymHandler.cleanup()
    }
}
