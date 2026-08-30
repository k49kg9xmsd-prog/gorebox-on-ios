import UIKit
import SceneKit

final class GameViewController: UIViewController, UIGestureRecognizerDelegate {
    private let sceneView = SCNView(frame: .zero)
    private let scene = SCNScene()
    private let playerNode = SCNNode()
    private let cameraPivot = SCNNode()
    private let cameraNode = SCNNode()
    private let joystick = VirtualJoystick(frame: .zero)
    private let fireButton = HoldButton(title: "FIRE")
    private let jumpButton = HoldButton(title: "JUMP")
    private let resetButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let crosshair = CrosshairView(frame: .zero)

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var verticalVelocity: Float = 0
    private var isGrounded = true
    private var fireCooldown: Float = 0
    private var flashView: UIView?

    private let walkSpeed: Float = 5.4
    private let gravity: Float = -18
    private let jumpVelocity: Float = 7.2

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildSceneView()
        buildWorld()
        buildPlayer()
        buildHUD()
        buildGestures()
        startLoop()
    }

    deinit {
        displayLink?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sceneView.frame = view.bounds

        let safe = view.safeAreaInsets
        let size = min(180, max(132, view.bounds.height * 0.27))
        joystick.frame = CGRect(
            x: safe.left + 34,
            y: view.bounds.height - safe.bottom - size - 28,
            width: size,
            height: size
        )

        let fireSize: CGFloat = min(126, view.bounds.height * 0.19)
        fireButton.frame = CGRect(
            x: view.bounds.width - safe.right - fireSize - 34,
            y: view.bounds.height - safe.bottom - fireSize - 42,
            width: fireSize,
            height: fireSize
        )

        let jumpSize: CGFloat = min(104, view.bounds.height * 0.16)
        jumpButton.frame = CGRect(
            x: fireButton.frame.minX - jumpSize - 24,
            y: fireButton.frame.midY - jumpSize / 2 - 30,
            width: jumpSize,
            height: jumpSize
        )

        resetButton.frame = CGRect(
            x: view.bounds.width - safe.right - 116,
            y: safe.top + 18,
            width: 92,
            height: 38
        )

        statusLabel.frame = CGRect(
            x: safe.left + 20,
            y: safe.top + 12,
            width: view.bounds.width - safe.left - safe.right - 160,
            height: 48
        )
        crosshair.frame = CGRect(x: view.bounds.midX - 18, y: view.bounds.midY - 18, width: 36, height: 36)
    }

    private func buildSceneView() {
        sceneView.scene = scene
        sceneView.backgroundColor = UIColor(red: 0.055, green: 0.06, blue: 0.07, alpha: 1)
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = true
        sceneView.preferredFramesPerSecond = 60
        sceneView.isPlaying = true
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        view.addSubview(sceneView)
    }

    private func material(_ color: UIColor, roughness: CGFloat = 0.75) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = 0.05
        return m
    }

    private func buildWorld() {
        let floor = SCNNode(geometry: SCNFloor())
        floor.name = "Ground"
        floor.geometry?.materials = [material(UIColor(white: 0.19, alpha: 1))]
        floor.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        scene.rootNode.addChildNode(floor)

        let grid = SCNNode(geometry: SCNPlane(width: 60, height: 60))
        grid.eulerAngles.x = -.pi / 2
        grid.position.y = 0.006
        let gridMat = SCNMaterial()
        gridMat.diffuse.contents = makeGridImage()
        gridMat.diffuse.wrapS = .repeat
        gridMat.diffuse.wrapT = .repeat
        gridMat.diffuse.contentsTransform = SCNMatrix4MakeScale(20, 20, 1)
        gridMat.lightingModel = .constant
        grid.geometry?.materials = [gridMat]
        scene.rootNode.addChildNode(grid)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 520
        ambient.color = UIColor(white: 0.58, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1200
        sun.castsShadow = true
        sun.shadowRadius = 5
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-0.85, -0.6, 0)
        scene.rootNode.addChildNode(sunNode)

        for row in 0..<4 {
            for col in 0..<7 {
                let box = SCNBox(width: 1.05, height: 1.0, length: 1.0, chamferRadius: 0.035)
                box.materials = [material(UIColor(red: 0.38, green: 0.30, blue: 0.21, alpha: 1), roughness: 0.9)]
                let node = SCNNode(geometry: box)
                node.name = "PhysicsBox"
                node.position = SCNVector3(Float(col - 3) * 1.12, 0.52 + Float(row) * 1.02, 10.5)
                node.physicsBody = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: box, options: nil))
                node.physicsBody?.mass = 1.1
                node.physicsBody?.friction = 0.75
                scene.rootNode.addChildNode(node)
            }
        }

        for i in 0..<7 {
            let pillar = SCNCylinder(radius: 0.58, height: 3.1)
            pillar.materials = [material(UIColor(white: 0.25, alpha: 1))]
            let node = SCNNode(geometry: pillar)
            node.position = SCNVector3(-7.5 + Float(i) * 2.5, 1.55, 18)
            node.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
            scene.rootNode.addChildNode(node)
        }

        let ramp = SCNBox(width: 6, height: 0.35, length: 7, chamferRadius: 0.04)
        ramp.materials = [material(UIColor(white: 0.28, alpha: 1))]
        let rampNode = SCNNode(geometry: ramp)
        rampNode.position = SCNVector3(8, 1.25, 8)
        rampNode.eulerAngles.x = -0.28
        rampNode.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        scene.rootNode.addChildNode(rampNode)
    }

    private func buildPlayer() {
        playerNode.name = "Player"
        playerNode.position = SCNVector3(0, 1.62, -6)
        scene.rootNode.addChildNode(playerNode)

        cameraPivot.position = SCNVector3Zero
        playerNode.addChildNode(cameraPivot)

        let camera = SCNCamera()
        camera.fieldOfView = 72
        camera.zNear = 0.03
        camera.zFar = 250
        camera.wantsHDR = true
        cameraNode.camera = camera
        cameraPivot.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
    }

    private func buildHUD() {
        joystick.layer.zPosition = 10
        view.addSubview(joystick)

        fireButton.layer.zPosition = 10
        fireButton.onPressChanged = { [weak self] pressed in
            if pressed { self?.fire() }
        }
        view.addSubview(fireButton)

        jumpButton.layer.zPosition = 10
        jumpButton.onPressChanged = { [weak self] pressed in
            guard pressed else { return }
            self?.jump()
        }
        view.addSubview(jumpButton)

        resetButton.setTitle("RESET", for: .normal)
        resetButton.setTitleColor(.white, for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        resetButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        resetButton.layer.cornerRadius = 10
        resetButton.addTarget(self, action: #selector(resetScene), for: .touchUpInside)
        resetButton.layer.zPosition = 10
        view.addSubview(resetButton)

        statusLabel.text = "GoreBox iOS POC 0.1  •  Native SceneKit  •  Move / Look / Jump / Fire"
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        statusLabel.numberOfLines = 2
        statusLabel.layer.zPosition = 10
        view.addSubview(statusLabel)

        crosshair.isUserInteractionEnabled = false
        crosshair.layer.zPosition = 11
        view.addSubview(crosshair)
    }

    private func buildGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLook(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self
        sceneView.addGestureRecognizer(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view else { return true }
        if touched.isDescendant(of: joystick) || touched.isDescendant(of: fireButton) || touched.isDescendant(of: jumpButton) || touched.isDescendant(of: resetButton) {
            return false
        }
        return touch.location(in: view).x > view.bounds.width * 0.30
    }

    @objc private func handleLook(_ pan: UIPanGestureRecognizer) {
        let delta = pan.translation(in: sceneView)
        pan.setTranslation(.zero, in: sceneView)
        let scale = Float(0.0044)
        yaw -= Float(delta.x) * scale
        pitch -= Float(delta.y) * scale
        pitch = max(-1.36, min(1.36, pitch))
        playerNode.eulerAngles.y = yaw
        cameraPivot.eulerAngles.x = pitch
    }

    private func startLoop() {
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard lastTimestamp > 0 else {
            lastTimestamp = link.timestamp
            return
        }
        var dt = Float(link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        dt = min(dt, 1.0 / 20.0)
        updatePlayer(dt: dt)
        fireCooldown = max(0, fireCooldown - dt)
        if fireButton.isPressed && fireCooldown <= 0 { fire() }
    }

    private func updatePlayer(dt: Float) {
        let input = joystick.vector
        let forward = SCNVector3(-sinf(yaw), 0, -cosf(yaw))
        let right = SCNVector3(cosf(yaw), 0, -sinf(yaw))
        let delta = SCNVector3(
            (right.x * input.x + forward.x * input.y) * walkSpeed * dt,
            0,
            (right.z * input.x + forward.z * input.y) * walkSpeed * dt
        )

        verticalVelocity += gravity * dt
        var y = playerNode.position.y + verticalVelocity * dt
        if y <= 1.62 {
            y = 1.62
            verticalVelocity = 0
            isGrounded = true
        }

        var newPos = playerNode.position
        newPos.x += delta.x
        newPos.z += delta.z
        newPos.y = y
        newPos.x = max(-24, min(24, newPos.x))
        newPos.z = max(-24, min(28, newPos.z))
        playerNode.position = newPos
    }

    private func jump() {
        guard isGrounded else { return }
        isGrounded = false
        verticalVelocity = jumpVelocity
    }

    private func fire() {
        guard fireCooldown <= 0 else { return }
        fireCooldown = 0.11
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let hits = sceneView.hitTest(center, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true,
            SCNHitTestOption.boundingBoxOnly: false
        ])

        if let hit = hits.first, let body = hit.node.physicsBody, body.type == .dynamic {
            let dir = cameraNode.presentation.convertVector(SCNVector3(0, 0, -1), to: scene.rootNode).normalized
            body.applyForce(dir * 15.5, at: hit.worldCoordinates, asImpulse: true)
            flash(node: hit.node)
        }
        muzzleFlash()
    }

    private func flash(node: SCNNode) {
        guard let material = node.geometry?.firstMaterial else { return }
        let oldEmission = material.emission.contents
        material.emission.contents = UIColor.white
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            material.emission.contents = oldEmission
        }
    }

    private func muzzleFlash() {
        flashView?.removeFromSuperview()
        let flash = UIView(frame: view.bounds)
        flash.backgroundColor = UIColor.white.withAlphaComponent(0.055)
        flash.isUserInteractionEnabled = false
        flash.layer.zPosition = 5
        view.insertSubview(flash, aboveSubview: sceneView)
        flashView = flash
        UIView.animate(withDuration: 0.08, animations: {
            flash.alpha = 0
        }, completion: { _ in
            flash.removeFromSuperview()
        })
    }

    @objc private func resetScene() {
        for node in scene.rootNode.childNodes where node.name == "PhysicsBox" {
            node.removeFromParentNode()
        }
        for row in 0..<4 {
            for col in 0..<7 {
                let box = SCNBox(width: 1.05, height: 1.0, length: 1.0, chamferRadius: 0.035)
                box.materials = [material(UIColor(red: 0.38, green: 0.30, blue: 0.21, alpha: 1), roughness: 0.9)]
                let node = SCNNode(geometry: box)
                node.name = "PhysicsBox"
                node.position = SCNVector3(Float(col - 3) * 1.12, 0.52 + Float(row) * 1.02, 10.5)
                node.physicsBody = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: box, options: nil))
                node.physicsBody?.mass = 1.1
                scene.rootNode.addChildNode(node)
            }
        }
        playerNode.position = SCNVector3(0, 1.62, -6)
        yaw = 0
        pitch = 0
        playerNode.eulerAngles = SCNVector3Zero
        cameraPivot.eulerAngles = SCNVector3Zero
        verticalVelocity = 0
        isGrounded = true
    }

    private func makeGridImage() -> UIImage {
        let size = CGSize(width: 96, height: 96)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.045).setStroke()
            let path = UIBezierPath()
            path.lineWidth = 1
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: size.width, y: 1))
            path.move(to: CGPoint(x: 1, y: 0))
            path.addLine(to: CGPoint(x: 1, y: size.height))
            path.stroke()
        }
    }
}

private extension SCNVector3 {
    static func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
        SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    var normalized: SCNVector3 {
        let l = sqrtf(x * x + y * y + z * z)
        guard l > 0.0001 else { return SCNVector3Zero }
        return SCNVector3(x / l, y / l, z / l)
    }
}
