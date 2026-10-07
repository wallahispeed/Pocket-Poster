//
//  PhysicsWallpaperGenerator.swift
//  Pocket Poster
//

import Foundation
import SpriteKit
import Metal
import AVFoundation
import UIKit

enum PhysicsWallpaperGenerator {

    // MARK: - Public

    /// Build the SpriteKit scene on the main thread.
    static func buildScene() -> SKScene {
        let size = CGSize(width: 393, height: 852) // iPhone 16 Pro logical points
        let scene = SKScene(size: size)
        scene.backgroundColor = .black
        scene.physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)
        scene.physicsWorld.speed = 1.0

        let walls = SKNode()
        walls.physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(origin: .zero, size: size))
        walls.physicsBody?.restitution = 0.5
        walls.physicsBody?.friction = 0.1
        scene.addChild(walls)

        let colors: [UIColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .cyan, .systemBlue, .systemIndigo, .systemPurple,
            .systemPink, .white
        ]
        let radius: CGFloat = 16

        for i in 0..<40 {
            let ball = SKShapeNode(circleOfRadius: radius)
            ball.fillColor = colors[i % colors.count]
            ball.strokeColor = .clear
            ball.glowWidth = 0

            let body = SKPhysicsBody(circleOfRadius: radius)
            body.restitution = CGFloat.random(in: 0.55...0.85)
            body.friction = 0.05
            body.linearDamping = 0
            body.angularDamping = 0.05

            let x = radius + CGFloat(i) / 40.0 * (size.width - 2 * radius)
            let y = CGFloat.random(in: 200...700)
            ball.position = CGPoint(x: x, y: y)
            ball.physicsBody = body
            scene.addChild(ball)
        }

        return scene
    }

    /// Render frames, encode video, build CAML descriptor, apply via bad_query.
    /// Call on a background thread. `onChange` is dispatched to main thread.
    static func apply(scene: SKScene, appHash: String, onChange: @escaping (String) -> Void) throws {
        // 1. Render physics to .mp4
        onChange("Rendering physics frames (0%)…")
        let videoURL = try renderVideo(scene: scene, onChange: onChange)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        // 2. Build CAML descriptor from video (reuses Pocket Poster's existing pipeline)
        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Building CAML descriptor…") }
        let descriptorURL = try VideoHandler.createCaml(from: videoURL, autoReverses: true)

        // 3. Apply the descriptor via bad_query (or legacy symlink)
        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Applying descriptor…") }
        try applyDescriptor(appHash: appHash, descriptorURL: descriptorURL)

        DispatchQueue.main.async { UIApplication.shared.change(title: "Physics Wallpaper", body: "Done — respinging…") }
    }

    // MARK: - Video rendering

    private static func renderVideo(scene: SKScene, onChange: @escaping (String) -> Void) throws -> URL {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(domain: "PhysicsWallpaper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Metal unavailable on this device"])
        }

        let renderer = SKRenderer(device: device)
        renderer.scene = scene

        let w = Int(scene.size.width), h = Int(scene.size.height)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        guard let tex = device.makeTexture(descriptor: texDesc) else {
            throw NSError(domain: "PhysicsWallpaper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate Metal texture"])
        }

        let rPass = MTLRenderPassDescriptor()
        rPass.colorAttachments[0].texture = tex
        rPass.colorAttachments[0].loadAction = .clear
        rPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rPass.colorAttachments[0].storeAction = .store

        let fps = 30.0
        let duration = 8.0
        let totalFrames = Int(fps * duration)
        let viewport = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

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

        for f in 0..<totalFrames {
            let t = Double(f) / fps

            guard let cmd = queue.makeCommandBuffer() else { continue }
            renderer.update(atTime: t)
            renderer.render(withViewport: viewport, commandBuffer: cmd, renderPassDescriptor: rPass)
            cmd.commit()
            cmd.waitUntilCompleted()

            // Metal texture → CVPixelBuffer
            var pb: CVPixelBuffer?
            let attrs: CFDictionary = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h
            ] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb)
            if let pb = pb {
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    tex.getBytes(base, bytesPerRow: w * 4,
                                 from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                }
                CVPixelBufferUnlockBaseAddress(pb, [])

                let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
                while !videoInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                adaptor.append(pb, withPresentationTime: pts)
            }

            if f % 15 == 0 {
                let pct = Int(Double(f + 1) / Double(totalFrames) * 100)
                DispatchQueue.main.async {
                    UIApplication.shared.change(title: "Physics Wallpaper",
                                                body: "Rendering physics frames (\(pct)%)…")
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

        if SymHandler.prefersBadQuery {
            let uuids = try SymHandler.writeDescriptorsViaBadQuery(
                appHash: appHash, ext: ext, descriptorFolders: [descriptorURL])
            SymHandler.writeToPosterBoardDB(appHash: appHash,
                                             entries: uuids.map { (uuid: $0, ext: ext) })
        } else {
            _ = try SymHandler.createDescriptorsSymlink(appHash: appHash, ext: ext)
            let dst = SymHandler.getDocumentsDirectory()
                .appendingPathComponent(UUID().uuidString, conformingTo: .directory)
            try FileManager.default.copyItem(at: descriptorURL, to: dst)
            try FileManager.default.trashItem(at: dst, resultingItemURL: nil)
        }
        SymHandler.cleanup()
    }
}
