import WidgetKit
import SwiftUI
import SpriteKit

// Physics wallpaper extension for Pocket Poster.
// Uses LiveSceneWidgetConfiguration (iOS 26+) to get a real UIScene
// with a full rendering surface — no exploit needed, no entitlement needed.
// Edit PhysicsScene.swift to change what the wallpaper looks like.

@main
struct PhysicsWallpaperBundle: Widget {

    let kind = "com.mak5er.pocketposter.physics-wallpaper"

    var body: some WidgetConfiguration {
        LiveSceneWidgetConfiguration(kind: kind)
            .configurationDisplayName("Physics Wallpaper")
            .description("Animated physics wallpaper by Pocket Poster.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
