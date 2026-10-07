import WidgetKit
import SwiftUI

// LiveSceneWidgetConfiguration exists in WidgetKit.framework at runtime
// but is not exported in the public SDK module interface.
// We use StaticConfiguration as the declared type and patch the CHS
// descriptor directly via ObjC runtime in WallpaperBootstrap.swift.

struct _EmptyEntry: TimelineEntry { let date = Date() }

struct _EmptyProvider: TimelineProvider {
    func placeholder(in context: Context) -> _EmptyEntry { _EmptyEntry() }
    func getSnapshot(in context: Context, completion: @escaping (_EmptyEntry) -> Void) { completion(_EmptyEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<_EmptyEntry>) -> Void) {
        completion(Timeline(entries: [_EmptyEntry()], policy: .never))
    }
}

@main
struct PhysicsWallpaperBundle: Widget {
    let kind = "com.mak5er.Pocket-Poster.physics-wallpaper"

    init() {
        // Patch CHSMutableWidgetDescriptor.setKind: before WidgetKit
        // processes our configuration, so wantsLiveScene is set to YES.
        WallpaperBootstrap.install()
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: _EmptyProvider()) { _ in
            Color.black.ignoresSafeArea()
        }
        .configurationDisplayName("Physics Wallpaper")
        .description("Animated physics wallpaper by Pocket Poster.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
