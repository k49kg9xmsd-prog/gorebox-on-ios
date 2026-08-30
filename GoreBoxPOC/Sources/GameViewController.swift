import UIKit
import SceneKit

final class GameViewController: UIViewController, UIGestureRecognizerDelegate {
    private let sceneView = SCNView(frame: .zero)
    private let scene = SCNScene()
    private let playerNode = SCNNode()
    private let cameraPivot = SCNNode()
    private let cameraNode = SCNNode()
    private let weaponNode = SCNNode()
    private let muzzleNode = SCNNode()

    private let joystick = VirtualJoystick(frame: .zero)
    private let fireButton = HoldButton(title: "✦", fontSize: 26)
    private let jumpButton = HoldButton(title: "↑", fontSize: 30)
    private let aimButton = HUDIconButton(glyph: "◎", fontSize: 28, circular: true)
    private let reloadButton = HUDIconButton(glyph: "↻", fontSize: 25, circular: true)
    private let crouchButton = HUDIconButton(glyph: "↓", fontSize: 28, circular: true)
    private let menuButton = HUDIconButton(glyph: "☰", fontSize: 30)
    private let spawnButton = HUDIconButton(glyph: "▣", fontSize: 25)
    private let chatButton = HUDIconButton(glyph: "●", fontSize: 22)
    private let handButton = HUDIconButton(glyph: "✋", fontSize: 23)
    private let resetButton = HUDIconButton(glyph: "↺", fontSize: 25)
    private let spawnMenu = SpawnMenuView(frame: .zero)
    private let crosshair = CrosshairView(frame: .zero)
    private let ammoLabel = UILabel()
    private let weaponLabel = UILabel()
    private let healthLabel = UILabel()

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var verticalVelocity: Float = 0
    private var isGrounded = true
    private var fireCooldown: Float = 0
    private var flashView: UIView?
    private var isAiming = false
    private var isCrouching = false
    private var ammo = 30
    private let maxAmmo = 30
    private var spawnedIndex = 0
    private var staticObstacleRects: [CGRect] = []

    private let walkSpeed: Float = 5.5
    private let gravity: Float = -18
    private let jumpVelocity: Float = 7.0
    private let normalEyeHeight: Float = 1.62
    private let crouchEyeHeight: Float = 1.08

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
        wireSpawnMenu()
        startLoop()
    }

    deinit { displayLink?.invalidate() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sceneView.frame = view.bounds
        let safe = view.safeAreaInsets
        let h = view.bounds.height

        let joySize = min(168, max(132, h * 0.245))
        joystick.frame = CGRect(x: safe.left + 34, y: h - safe.bottom - joySize - 22, width: joySize, height: joySize)

        let fireSize = min(112, h * 0.17)
        fireButton.frame = CGRect(x: view.bounds.width - safe.right - fireSize - 28, y: h - safe.bottom - fireSize - 32, width: fireSize, height: fireSize)

        let jumpSize = min(92, h * 0.14)
        jumpButton.frame = CGRect(x: fireButton.frame.minX - jumpSize - 20, y: fireButton.frame.midY - jumpSize / 2 - 32, width: jumpSize, height: jumpSize)

        let small: CGFloat = min(74, h * 0.112)
        aimButton.frame = CGRect(x: fireButton.frame.midX - small / 2, y: fireButton.frame.minY - small - 16, width: small, height: small)
        reloadButton.frame = CGRect(x: fireButton.frame.minX - small - 12, y: fireButton.frame.maxY - small * 0.82, width: small, height: small)
        crouchButton.frame = CGRect(x: jumpButton.frame.minX - small - 14, y: jumpButton.frame.minY + 4, width: small, height: small)

        let topY = safe.top + 15
        let topSize: CGFloat = 48
        menuButton.frame = CGRect(x: safe.left + 22, y: topY, width: topSize, height: topSize)
        spawnButton.frame = CGRect(x: menuButton.frame.maxX + 8, y: topY, width: topSize, height: topSize)
        chatButton.frame = CGRect(x: spawnButton.frame.maxX + 8, y: topY, width: topSize, height: topSize)
        handButton.frame = CGRect(x: chatButton.frame.maxX + 8, y: topY, width: topSize, height: topSize)
        resetButton.frame = CGRect(x: view.bounds.width - safe.right - topSize - 20, y: topY, width: topSize, height: topSize)

        ammoLabel.frame = CGRect(x: view.bounds.width - safe.right - 220, y: safe.top + 18, width: 145, height: 28)
        weaponLabel.frame = CGRect(x: view.bounds.width - safe.right - 220, y: safe.top + 45, width: 145, height: 24)
        healthLabel.frame = CGRect(x: safe.left + 24, y: h - safe.bottom - joySize - 57, width: 150, height: 26)
        crosshair.frame = CGRect(x: view.bounds.midX - 26, y: view.bounds.midY - 26, width: 52, height: 52)

        spawnMenu.frame = CGRect(x: safe.left + 22, y: menuButton.frame.maxY + 8, width: 180, height: min(330, h - topY - topSize - safe.bottom - 20))
    }

    private func buildSceneView() {
        sceneView.scene = scene
        sceneView.backgroundColor = UIColor(red: 0.35, green: 0.58, blue: 0.82, alpha: 1)
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = true
        sceneView.preferredFramesPerSecond = 60
        sceneView.isPlaying = true
        scene.physicsWorld.gravity = SCNVector3(0, -9.81, 0)
        view.addSubview(sceneView)
    }

    private func material(_ color: UIColor, roughness: CGFloat = 0.82, metal: CGFloat = 0.02) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metal
        return m
    }

    private func addBox(name: String, size: SCNVector3, pos: SCNVector3, color: UIColor, dynamic: Bool = false, obstacle: Bool = false, chamfer: CGFloat = 0.02) -> SCNNode {
        let geo = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: chamfer)
        geo.materials = [material(color)]
        let node = SCNNode(geometry: geo)
        node.name = name
        node.position = pos
        node.physicsBody = SCNPhysicsBody(type: dynamic ? .dynamic : .static, shape: SCNPhysicsShape(geometry: geo, options: nil))
        if dynamic {
            node.physicsBody?.mass = 1.0
            node.physicsBody?.friction = 0.75
            node.physicsBody?.restitution = 0.08
        }
        scene.rootNode.addChildNode(node)
        if obstacle && !dynamic {
            staticObstacleRects.append(CGRect(x: CGFloat(pos.x - size.x/2 - 0.35), y: CGFloat(pos.z - size.z/2 - 0.35), width: CGFloat(size.x + 0.7), height: CGFloat(size.z + 0.7)))
        }
        return node
    }

    private func buildWorld() {
        let ground = SCNNode(geometry: SCNFloor())
        ground.name = "Ground"
        ground.geometry?.materials = [material(UIColor(red: 0.27, green: 0.39, blue: 0.23, alpha: 1))]
        ground.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        scene.rootNode.addChildNode(ground)

        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 650; ambient.color = UIColor(white: 0.76, alpha: 1)
        let ambientNode = SCNNode(); ambientNode.light = ambient; scene.rootNode.addChildNode(ambientNode)
        let sun = SCNLight(); sun.type = .directional; sun.intensity = 1250; sun.castsShadow = true; sun.shadowRadius = 4
        let sunNode = SCNNode(); sunNode.light = sun; sunNode.eulerAngles = SCNVector3(-0.9, -0.55, -0.1); scene.rootNode.addChildNode(sunNode)

        addBox(name: "ConcretePad", size: SCNVector3(26, 0.18, 25), pos: SCNVector3(0, 0.05, 9), color: UIColor(white: 0.56, alpha: 1))
        addBox(name: "Road", size: SCNVector3(10, 0.14, 75), pos: SCNVector3(-20, 0.04, 12), color: UIColor(white: 0.20, alpha: 1))

        addBox(name: "WarehouseFloor", size: SCNVector3(18, 0.3, 14), pos: SCNVector3(17, 0.15, 22), color: UIColor(white: 0.43, alpha: 1))
        addBox(name: "WarehouseBack", size: SCNVector3(18, 7, 0.4), pos: SCNVector3(17, 3.5, 28.8), color: UIColor(white: 0.28, alpha: 1), obstacle: true)
        addBox(name: "WarehouseLeft", size: SCNVector3(0.4, 7, 14), pos: SCNVector3(8.2, 3.5, 22), color: UIColor(white: 0.29, alpha: 1), obstacle: true)
        addBox(name: "WarehouseRight", size: SCNVector3(0.4, 7, 14), pos: SCNVector3(25.8, 3.5, 22), color: UIColor(white: 0.29, alpha: 1), obstacle: true)
        addBox(name: "WarehouseRoof", size: SCNVector3(18.4, 0.35, 14.4), pos: SCNVector3(17, 7.0, 22), color: UIColor(white: 0.24, alpha: 1))
        addBox(name: "WarehouseFrontL", size: SCNVector3(5.6, 7, 0.35), pos: SCNVector3(10.8, 3.5, 15.1), color: UIColor(white: 0.30, alpha: 1), obstacle: true)
        addBox(name: "WarehouseFrontR", size: SCNVector3(5.6, 7, 0.35), pos: SCNVector3(23.2, 3.5, 15.1), color: UIColor(white: 0.30, alpha: 1), obstacle: true)

        for i in 0..<8 {
            let z = Float(-13 + i * 7)
            addBox(name: "Fence", size: SCNVector3(0.22, 2.0, 5.5), pos: SCNVector3(31.5, 1.0, z), color: UIColor(white: 0.36, alpha: 1), obstacle: true, chamfer: 0)
        }

        for i in 0..<10 {
            let x = Float(-9 + (i % 5) * 2)
            let z = Float(6 + (i / 5) * 2)
            let crate = addBox(name: "Breakable", size: SCNVector3(1.25, 1.25, 1.25), pos: SCNVector3(x, 0.68, z), color: UIColor(red: 0.43, green: 0.31, blue: 0.19, alpha: 1), dynamic: true, chamfer: 0.03)
            crate.physicsBody?.mass = 1.4
        }

        for i in 0..<5 { addTree(x: Float(-31 + i * 7), z: Float(4 + (i % 2) * 14)) }
        for i in 0..<4 { addTree(x: Float(33 + i * 5), z: Float(-5 + i * 10)) }

        let ramp = addBox(name: "Ramp", size: SCNVector3(6, 0.35, 8), pos: SCNVector3(-7, 1.2, 20), color: UIColor(white: 0.48, alpha: 1))
        ramp.eulerAngles.x = -0.28

        addDummy(at: SCNVector3(0, 1.55, 13), spawned: false)
        addDummy(at: SCNVector3(4, 1.55, 15), spawned: false)
    }

    private func addTree(x: Float, z: Float) {
        let trunk = SCNCylinder(radius: 0.35, height: 3.8)
        trunk.materials = [material(UIColor(red: 0.31, green: 0.23, blue: 0.15, alpha: 1))]
        let trunkNode = SCNNode(geometry: trunk); trunkNode.position = SCNVector3(x, 1.9, z); trunkNode.physicsBody = SCNPhysicsBody(type: .static, shape: nil); scene.rootNode.addChildNode(trunkNode)
        let crown = SCNSphere(radius: 2.0); crown.materials = [material(UIColor(red: 0.18, green: 0.34, blue: 0.16, alpha: 1))]
        let crownNode = SCNNode(geometry: crown); crownNode.scale = SCNVector3(1.2, 0.85, 1.2); crownNode.position = SCNVector3(x, 4.5, z); scene.rootNode.addChildNode(crownNode)
    }

    private func buildPlayer() {
        playerNode.name = "Player"
        playerNode.position = SCNVector3(0, normalEyeHeight, -8)
        scene.rootNode.addChildNode(playerNode)
        cameraPivot.position = SCNVector3Zero
        playerNode.addChildNode(cameraPivot)

        let camera = SCNCamera(); camera.fieldOfView = 76; camera.zNear = 0.03; camera.zFar = 400; camera.wantsHDR = true
        cameraNode.camera = camera; cameraPivot.addChildNode(cameraNode); sceneView.pointOfView = cameraNode
        buildWeaponViewModel()
    }

    private func buildWeaponViewModel() {
        weaponNode.name = "ViewModel"
        cameraNode.addChildNode(weaponNode)
        weaponNode.position = SCNVector3(0.31, -0.26, -0.66)
        weaponNode.eulerAngles = SCNVector3(0.02, -0.06, 0)

        func gunPart(_ size: SCNVector3, _ pos: SCNVector3, _ color: UIColor) {
            let geo = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.012)
            geo.materials = [material(color, roughness: 0.48, metal: 0.28)]
            let n = SCNNode(geometry: geo); n.position = pos; weaponNode.addChildNode(n)
        }
        gunPart(SCNVector3(0.24,0.18,0.55), SCNVector3(0,0,0), UIColor(white: 0.08, alpha: 1))
        gunPart(SCNVector3(0.13,0.11,0.58), SCNVector3(0.0,0.03,-0.50), UIColor(white: 0.10, alpha: 1))
        gunPart(SCNVector3(0.16,0.34,0.12), SCNVector3(-0.01,-0.21,-0.02), UIColor(white: 0.07, alpha: 1))
        gunPart(SCNVector3(0.18,0.13,0.32), SCNVector3(0.0,0.02,0.42), UIColor(white: 0.11, alpha: 1))
        gunPart(SCNVector3(0.08,0.09,0.27), SCNVector3(0,0.10,-0.18), UIColor(white: 0.04, alpha: 1))
        muzzleNode.position = SCNVector3(0, 0.03, -0.84); weaponNode.addChildNode(muzzleNode)
    }

    private func buildHUD() {
        [joystick, fireButton, jumpButton, aimButton, reloadButton, crouchButton, menuButton, spawnButton, chatButton, handButton, resetButton, crosshair, ammoLabel, weaponLabel, healthLabel, spawnMenu].forEach { $0.layer.zPosition = 10; view.addSubview($0) }
        crosshair.isUserInteractionEnabled = false; crosshair.layer.zPosition = 11
        spawnMenu.isHidden = true; spawnMenu.layer.zPosition = 20

        fireButton.onPressChanged = { [weak self] pressed in if pressed { self?.fire() } }
        jumpButton.onPressChanged = { [weak self] pressed in if pressed { self?.jump() } }
        aimButton.onTap = { [weak self] in self?.toggleAim() }
        reloadButton.onTap = { [weak self] in self?.reload() }
        crouchButton.onTap = { [weak self] in self?.toggleCrouch() }
        menuButton.onTap = { [weak self] in self?.spawnMenu.isHidden.toggle() }
        spawnButton.onTap = { [weak self] in self?.spawnMenu.isHidden.toggle() }
        chatButton.onTap = { [weak self] in self?.showToast("Offline build") }
        handButton.onTap = { [weak self] in self?.interactPush() }
        resetButton.onTap = { [weak self] in self?.resetPlayer() }

        ammoLabel.textColor = .white; ammoLabel.textAlignment = .right; ammoLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .heavy)
        weaponLabel.textColor = UIColor.white.withAlphaComponent(0.72); weaponLabel.textAlignment = .right; weaponLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold); weaponLabel.text = "CARBINE"
        healthLabel.textColor = UIColor.white.withAlphaComponent(0.82); healthLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold); healthLabel.text = "100  HP"
        updateAmmoLabel()
    }

    private func wireSpawnMenu() {
        spawnMenu.onSpawnCrate = { [weak self] in self?.spawnCrate() }
        spawnMenu.onSpawnDummy = { [weak self] in self?.addDummy(at: self?.spawnPoint(distance: 5.2) ?? SCNVector3Zero, spawned: true) }
        spawnMenu.onSpawnBarrel = { [weak self] in self?.spawnBarrel() }
        spawnMenu.onSpawnBall = { [weak self] in self?.spawnBall() }
        spawnMenu.onClearSpawned = { [weak self] in self?.clearSpawned() }
    }

    private func buildGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLook(_:)))
        pan.maximumNumberOfTouches = 1; pan.cancelsTouchesInView = false; pan.delegate = self; sceneView.addGestureRecognizer(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view else { return true }
        let controls: [UIView] = [joystick, fireButton, jumpButton, aimButton, reloadButton, crouchButton, menuButton, spawnButton, chatButton, handButton, resetButton, spawnMenu]
        if controls.contains(where: { touched.isDescendant(of: $0) || touched === $0 }) { return false }
        return touch.location(in: view).x > view.bounds.width * 0.27
    }

    @objc private func handleLook(_ pan: UIPanGestureRecognizer) {
        let delta = pan.translation(in: sceneView); pan.setTranslation(.zero, in: sceneView)
        let scale = Float(isAiming ? 0.0025 : 0.0042)
        yaw -= Float(delta.x) * scale; pitch -= Float(delta.y) * scale; pitch = max(-1.36, min(1.36, pitch))
        playerNode.eulerAngles.y = yaw; cameraPivot.eulerAngles.x = pitch
    }

    private func startLoop() {
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:))); link.add(to: .main, forMode: .common); displayLink = link
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard lastTimestamp > 0 else { lastTimestamp = link.timestamp; return }
        var dt = Float(link.timestamp - lastTimestamp); lastTimestamp = link.timestamp; dt = min(dt, 1.0 / 20.0)
        updatePlayer(dt: dt); fireCooldown = max(0, fireCooldown - dt)
        if fireButton.isPressed && fireCooldown <= 0 { fire() }
    }

    private func updatePlayer(dt: Float) {
        let input = joystick.vector
        let forward = SCNVector3(-sinf(yaw), 0, -cosf(yaw)); let right = SCNVector3(cosf(yaw), 0, -sinf(yaw))
        let speed = walkSpeed * (isCrouching ? 0.58 : 1.0)
        let delta = SCNVector3((right.x * input.x + forward.x * input.y) * speed * dt, 0, (right.z * input.x + forward.z * input.y) * speed * dt)

        verticalVelocity += gravity * dt
        let targetHeight = isCrouching ? crouchEyeHeight : normalEyeHeight
        var y = playerNode.position.y + verticalVelocity * dt
        if y <= targetHeight { y = targetHeight; verticalVelocity = 0; isGrounded = true }

        var candidate = playerNode.position; candidate.x += delta.x; candidate.z += delta.z; candidate.y = y
        candidate.x = max(-46, min(46, candidate.x)); candidate.z = max(-35, min(58, candidate.z))
        if !hitsStaticObstacle(candidate) { playerNode.position = candidate } else { playerNode.position.y = y }
    }

    private func hitsStaticObstacle(_ p: SCNVector3) -> Bool {
        let point = CGPoint(x: CGFloat(p.x), y: CGFloat(p.z))
        return staticObstacleRects.contains(where: { $0.contains(point) })
    }

    private func jump() {
        guard isGrounded, !isCrouching else { return }; isGrounded = false; verticalVelocity = jumpVelocity
    }

    private func toggleAim() {
        isAiming.toggle()
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.15
        cameraNode.camera?.fieldOfView = isAiming ? 47 : 76
        weaponNode.position = isAiming ? SCNVector3(0.02, -0.20, -0.61) : SCNVector3(0.31, -0.26, -0.66)
        SCNTransaction.commit()
    }

    private func toggleCrouch() {
        isCrouching.toggle(); if isCrouching { verticalVelocity = 0 }
    }

    private func reload() {
        guard ammo < maxAmmo else { return }
        showToast("RELOADING")
        UIView.animate(withDuration: 0.18, animations: { self.reloadButton.transform = CGAffineTransform(rotationAngle: .pi) }) { _ in
            UIView.animate(withDuration: 0.18, animations: { self.reloadButton.transform = .identity }) { _ in self.ammo = self.maxAmmo; self.updateAmmoLabel() }
        }
    }

    private func fire() {
        guard fireCooldown <= 0 else { return }
        guard ammo > 0 else { reload(); return }
        fireCooldown = 0.095; ammo -= 1; updateAmmoLabel(); animateRecoil(); muzzleFlash()
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let hits = sceneView.hitTest(center, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue, SCNHitTestOption.ignoreHiddenNodes: true])
        guard let hit = hits.first else { return }

        if let dummy = ancestor(namedAnyOf: ["Dummy", "SpawnedDummy"], from: hit.node) {
            ragdoll(dummy: dummy, hitPoint: hit.worldCoordinates); return
        }
        if let body = hit.node.physicsBody, body.type == .dynamic {
            let dir = cameraNode.presentation.convertVector(SCNVector3(0,0,-1), to: scene.rootNode).normalized
            body.applyForce(dir * 15.5, at: hit.worldCoordinates, asImpulse: true); flash(node: hit.node)
        }
    }

    private func animateRecoil() {
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.035
        weaponNode.position.z += 0.055; weaponNode.eulerAngles.x -= 0.035
        SCNTransaction.completionBlock = { [weak self] in
            guard let self = self else { return }
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.075
            self.weaponNode.position = self.isAiming ? SCNVector3(0.02,-0.20,-0.61) : SCNVector3(0.31,-0.26,-0.66); self.weaponNode.eulerAngles.x = 0.02
            SCNTransaction.commit()
        }
        SCNTransaction.commit()
    }

    private func interactPush() {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        if let hit = sceneView.hitTest(center, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue]).first, let body = hit.node.physicsBody, body.type == .dynamic {
            let dir = cameraNode.presentation.convertVector(SCNVector3(0,0,-1), to: scene.rootNode).normalized
            body.applyForce(dir * 7.5, at: hit.worldCoordinates, asImpulse: true)
        }
    }

    private func ancestor(namedAnyOf names: Set<String>, from node: SCNNode) -> SCNNode? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name, names.contains(name) { return current }
            n = current.parent
        }
        return nil
    }

    private func ragdoll(dummy: SCNNode, hitPoint: SCNVector3) {
        let base = dummy.presentation.position; let tag = dummy.name == "SpawnedDummy" ? "Spawned" : "Ragdoll"
        dummy.removeFromParentNode()
        let skin = UIColor(red: 0.58, green: 0.45, blue: 0.34, alpha: 1); let cloth = UIColor(red: 0.20, green: 0.28, blue: 0.32, alpha: 1)
        let parts: [(SCNVector3, SCNVector3, UIColor)] = [
            (SCNVector3(0,1.05,0), SCNVector3(0.48,0.55,0.28), skin),
            (SCNVector3(0,0.40,0), SCNVector3(0.75,0.82,0.40), cloth),
            (SCNVector3(-0.56,0.42,0), SCNVector3(0.28,0.82,0.28), skin),
            (SCNVector3(0.56,0.42,0), SCNVector3(0.28,0.82,0.28), skin),
            (SCNVector3(-0.22,-0.48,0), SCNVector3(0.30,0.95,0.32), cloth),
            (SCNVector3(0.22,-0.48,0), SCNVector3(0.30,0.95,0.32), cloth)
        ]
        for (offset,size,color) in parts {
            let node = addBox(name: tag, size: size, pos: base + offset, color: color, dynamic: true, chamfer: 0.05)
            node.physicsBody?.mass = 0.8; node.physicsBody?.damping = 0.14; node.physicsBody?.angularDamping = 0.12
            let dir = cameraNode.presentation.convertVector(SCNVector3(0,0,-1), to: scene.rootNode).normalized
            node.physicsBody?.applyForce(dir * 2.2 + SCNVector3(Float.random(in: -0.5...0.5), Float.random(in: 0.2...1.0), Float.random(in: -0.5...0.5)), asImpulse: true)
        }
        spawnBlood(at: hitPoint)
    }

    private func spawnBlood(at p: SCNVector3) {
        for _ in 0..<10 {
            let sphere = SCNSphere(radius: CGFloat.random(in: 0.025...0.065)); sphere.materials = [material(UIColor(red: 0.34, green: 0.02, blue: 0.02, alpha: 1), roughness: 0.7)]
            let node = SCNNode(geometry: sphere); node.name = "Blood"; node.position = p; node.physicsBody = SCNPhysicsBody(type: .dynamic, shape: nil); node.physicsBody?.mass = 0.03
            scene.rootNode.addChildNode(node)
            node.physicsBody?.applyForce(SCNVector3(Float.random(in: -1.7...1.7), Float.random(in: 0.5...2.2), Float.random(in: -1.7...1.7)), asImpulse: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { node.removeFromParentNode() }
        }
    }

    @discardableResult private func addDummy(at pos: SCNVector3, spawned: Bool) -> SCNNode {
        let root = SCNNode(); root.name = spawned ? "SpawnedDummy" : "Dummy"; root.position = SCNVector3(pos.x, 1.05, pos.z); scene.rootNode.addChildNode(root)
        func part(_ size: SCNVector3, _ local: SCNVector3, _ color: UIColor) -> SCNNode {
            let g = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.04); g.materials = [material(color)]
            let n = SCNNode(geometry: g); n.position = local; root.addChildNode(n); return n
        }
        let skin = UIColor(red: 0.58, green: 0.45, blue: 0.34, alpha: 1); let cloth = UIColor(red: 0.17, green: 0.26, blue: 0.31, alpha: 1)
        part(SCNVector3(0.52,0.56,0.32), SCNVector3(0,1.05,0), skin)
        part(SCNVector3(0.78,0.85,0.42), SCNVector3(0,0.38,0), cloth)
        part(SCNVector3(0.30,0.84,0.30), SCNVector3(-0.57,0.37,0), skin)
        part(SCNVector3(0.30,0.84,0.30), SCNVector3(0.57,0.37,0), skin)
        part(SCNVector3(0.31,0.95,0.34), SCNVector3(-0.23,-0.52,0), cloth)
        part(SCNVector3(0.31,0.95,0.34), SCNVector3(0.23,-0.52,0), cloth)
        let hitGeo = SCNBox(width: 1.35, height: 2.9, length: 0.8, chamferRadius: 0); let hitNode = SCNNode(geometry: hitGeo); hitNode.opacity = 0.001; hitNode.position = SCNVector3(0,0.18,0); root.addChildNode(hitNode)
        if spawned { root.name = "SpawnedDummy"; spawnedIndex += 1 }
        return root
    }

    private func spawnPoint(distance: Float) -> SCNVector3 {
        let forward = cameraNode.presentation.convertVector(SCNVector3(0,0,-1), to: scene.rootNode).normalized
        let p = cameraNode.presentation.convertPosition(SCNVector3Zero, to: scene.rootNode)
        return SCNVector3(p.x + forward.x * distance, 0.8, p.z + forward.z * distance)
    }

    private func spawnCrate() {
        let p = spawnPoint(distance: 4.5); let n = addBox(name: "Spawned", size: SCNVector3(1.2,1.2,1.2), pos: SCNVector3(p.x,0.75,p.z), color: UIColor(red:0.44,green:0.31,blue:0.18,alpha:1), dynamic: true, chamfer: 0.03); n.physicsBody?.mass = 1.3
    }

    private func spawnBarrel() {
        let p = spawnPoint(distance: 4.5); let g = SCNCylinder(radius: 0.48, height: 1.35); g.materials = [material(UIColor(red:0.18,green:0.20,blue:0.19,alpha:1), roughness:0.55, metal:0.4)]
        let n = SCNNode(geometry: g); n.name = "Spawned"; n.position = SCNVector3(p.x,0.75,p.z); n.physicsBody = SCNPhysicsBody(type:.dynamic, shape:nil); n.physicsBody?.mass = 1.6; scene.rootNode.addChildNode(n)
    }

    private func spawnBall() {
        let p = spawnPoint(distance: 4.5); let g = SCNSphere(radius:0.62); g.materials = [material(UIColor(white:0.14,alpha:1), roughness:0.45)]
        let n = SCNNode(geometry:g); n.name = "Spawned"; n.position = SCNVector3(p.x,1.0,p.z); n.physicsBody = SCNPhysicsBody(type:.dynamic, shape:nil); n.physicsBody?.mass = 0.8; n.physicsBody?.restitution = 0.65; scene.rootNode.addChildNode(n)
    }

    private func clearSpawned() {
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == "Spawned" || node.name == "Blood" { node.removeFromParentNode() }
            if node.name == "SpawnedDummy" { node.removeFromParentNode() }
        }
    }

    private func flash(node: SCNNode) {
        guard let m = node.geometry?.firstMaterial else { return }; let old = m.emission.contents; m.emission.contents = UIColor.white
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { m.emission.contents = old }
    }

    private func muzzleFlash() {
        flashView?.removeFromSuperview()
        let overlay = UIView(frame: view.bounds); overlay.backgroundColor = UIColor.white.withAlphaComponent(0.035); overlay.isUserInteractionEnabled = false; overlay.layer.zPosition = 5
        view.insertSubview(overlay, aboveSubview: sceneView); flashView = overlay
        let light = SCNLight(); light.type = .omni; light.intensity = 1800; light.color = UIColor(red:1,green:0.72,blue:0.35,alpha:1); muzzleNode.light = light
        DispatchQueue.main.asyncAfter(deadline:.now()+0.035) { self.muzzleNode.light = nil }
        UIView.animate(withDuration:0.06, animations:{ overlay.alpha = 0 }) { _ in overlay.removeFromSuperview() }
    }

    private func updateAmmoLabel() { ammoLabel.text = String(format: "%02d / %02d", ammo, maxAmmo) }

    private func showToast(_ text: String) {
        let l = UILabel(); l.text = text; l.textColor = .white; l.textAlignment = .center; l.font = .monospacedSystemFont(ofSize:13, weight:.bold); l.backgroundColor = UIColor.black.withAlphaComponent(0.55); l.layer.cornerRadius = 8; l.clipsToBounds = true; l.alpha = 0; l.layer.zPosition = 30
        l.frame = CGRect(x:view.bounds.midX-90, y:view.safeAreaInsets.top+22, width:180, height:34); view.addSubview(l)
        UIView.animate(withDuration:0.12, animations:{l.alpha=1}) { _ in UIView.animate(withDuration:0.2, delay:0.65, options:[], animations:{l.alpha=0}) { _ in l.removeFromSuperview() } }
    }

    private func resetPlayer() {
        playerNode.position = SCNVector3(0, normalEyeHeight, -8); yaw = 0; pitch = 0; verticalVelocity = 0; isGrounded = true; isCrouching = false
        playerNode.eulerAngles = SCNVector3Zero; cameraPivot.eulerAngles = SCNVector3Zero
    }
}

private extension SCNVector3 {
    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 { SCNVector3(lhs.x+rhs.x, lhs.y+rhs.y, lhs.z+rhs.z) }
    static func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 { SCNVector3(lhs.x*rhs, lhs.y*rhs, lhs.z*rhs) }
    var normalized: SCNVector3 {
        let l = sqrtf(x*x+y*y+z*z); guard l > 0.0001 else { return SCNVector3Zero }; return SCNVector3(x/l,y/l,z/l)
    }
}
