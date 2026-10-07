import UIKit
import SpriteKit

// SpringBoard creates a full UIWindowScene for this extension
// when LiveSceneWidgetConfiguration sets wantsLiveScene = YES.
// This delegate is instantiated via UIApplicationSceneManifest in Info.plist.

class PhysicsSceneDelegate: NSObject, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let skView = SKView()
        skView.allowsTransparency = true
        skView.backgroundColor = .clear
        skView.ignoresSiblingOrder = true
        skView.showsFPS = false
        skView.showsNodeCount = false

        let physicsScene = PhysicsScene(size: UIScreen.main.bounds.size)
        physicsScene.scaleMode = .resizeFill
        skView.presentScene(physicsScene)

        let rootVC = UIViewController()
        rootVC.view = skView
        rootVC.view.backgroundColor = .clear

        let win = UIWindow(windowScene: windowScene)
        win.rootViewController = rootVC
        win.makeKeyAndVisible()
        self.window = win
    }
}
