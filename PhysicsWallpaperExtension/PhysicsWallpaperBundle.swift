import WidgetKit
import SwiftUI

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
        // Runs in the extension process when WidgetKit loads the extension.
        // install() attempts to:
        //   1. dlopen HomeBoard/CoreHomeScreen and patch CHSMutableWidgetDescriptor.setKind:
        //   2. Enumerate WidgetKit classes looking for LiveSceneWidgetConfiguration
        //   3. Write pp_ext_bootstrap.txt diagnostic so we can see what was found
        WallpaperBootstrap.install()
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: _EmptyProvider()) { _ in
            Color.clear.ignoresSafeArea()
        }
        .configurationDisplayName("Physics Wallpaper")
        .description("Animated physics wallpaper by Pocket Poster.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
