import SpriteKit
import UIKit

// ─────────────────────────────────────────────────────────────────
// EDIT THIS FILE to change what the physics wallpaper looks like.
//
// Key tunables at the top:
//   ballCount    — how many objects
//   ballRadius   — size of each object
//   gravity      — direction + strength
//   restitution  — bounciness (0 = dead, 1 = perfect bounce)
//   ballColors   — what colors the objects cycle through
//
// To use images instead of colored circles:
//   Replace SKShapeNode with SKSpriteNode(imageNamed: "yourimage")
//   and set physicsBody = SKPhysicsBody(texture:size:)
// ─────────────────────────────────────────────────────────────────

@MainActor
class PhysicsScene: SKScene, SKPhysicsContactDelegate {

    // ── Tunables ──────────────────────────────────────────────────
    private let ballCount   = 40
    private let ballRadius: CGFloat = 18
    private let gravity     = CGVector(dx: 0, dy: -5.0)
    private let restitution: CGFloat = 0.75
    private let linearDamp: CGFloat  = 0.05
    private let ballColors: [UIColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemTeal, .systemBlue,
        .systemPurple, .systemPink, .white
    ]
    // ─────────────────────────────────────────────────────────────

    private let ballCategory: UInt32 = 0b01
    private let wallCategory: UInt32 = 0b10

    override func didMove(to view: SKView) {
        backgroundColor = .black
        physicsWorld.gravity = gravity
        physicsWorld.contactDelegate = self
        buildWalls()
        spawnBalls()
    }

    private func buildWalls() {
        let body = SKPhysicsBody(edgeLoopFrom: frame)
        body.friction    = 0.3
        body.restitution = restitution
        body.categoryBitMask  = wallCategory
        body.collisionBitMask = ballCategory
        let walls = SKNode()
        walls.physicsBody = body
        addChild(walls)
    }

    private func spawnBalls() {
        for i in 0..<ballCount {
            let ball = SKShapeNode(circleOfRadius: ballRadius)
            ball.fillColor   = ballColors[i % ballColors.count]
            ball.strokeColor = .clear
            ball.glowWidth   = 2
            ball.position = CGPoint(
                x: CGFloat.random(in: ballRadius...(size.width - ballRadius)),
                y: CGFloat.random(in: size.height * 0.4...size.height * 0.9)
            )

            let body = SKPhysicsBody(circleOfRadius: ballRadius)
            body.mass            = 1.0
            body.restitution     = restitution
            body.friction        = 0.2
            body.linearDamping   = linearDamp
            body.angularDamping  = 0.1
            body.allowsRotation  = true
            body.categoryBitMask    = ballCategory
            body.collisionBitMask   = ballCategory | wallCategory
            body.contactTestBitMask = ballCategory
            ball.physicsBody = body

            body.applyImpulse(CGVector(
                dx: CGFloat.random(in: -80...80),
                dy: CGFloat.random(in: -40...40)
            ))
            addChild(ball)
        }
    }

    func didBegin(_ contact: SKPhysicsContact) {
        for node in [contact.bodyA.node, contact.bodyB.node] {
            guard let ball = node as? SKShapeNode else { continue }
            ball.run(.sequence([
                .customAction(withDuration: 0) { n, _ in (n as? SKShapeNode)?.glowWidth = 8 },
                .wait(forDuration: 0.08),
                .customAction(withDuration: 0) { n, _ in (n as? SKShapeNode)?.glowWidth = 2 }
            ]))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        for node in nodes(at: touch.location(in: self)) {
            node.physicsBody?.applyImpulse(CGVector(
                dx: CGFloat.random(in: -200...200), dy: 400
            ))
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        removeAllChildren()
        buildWalls()
        spawnBalls()
    }
}
