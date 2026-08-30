import UIKit

final class VirtualJoystick: UIView {
    private let baseView = UIView()
    private let knobView = UIView()
    private(set) var vector = SIMD2<Float>(repeating: 0)
    private var trackingTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        baseView.backgroundColor = UIColor.black.withAlphaComponent(0.16)
        baseView.layer.borderColor = UIColor.white.withAlphaComponent(0.40).cgColor
        baseView.layer.borderWidth = 1.5
        knobView.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        knobView.layer.borderColor = UIColor.white.withAlphaComponent(0.48).cgColor
        knobView.layer.borderWidth = 1
        addSubview(baseView)
        addSubview(knobView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        baseView.frame = bounds
        baseView.layer.cornerRadius = bounds.width / 2
        let knob = bounds.width * 0.42
        knobView.bounds = CGRect(x: 0, y: 0, width: knob, height: knob)
        knobView.layer.cornerRadius = knob / 2
        if trackingTouch == nil { knobView.center = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackingTouch == nil, let t = touches.first else { return }
        trackingTouch = t
        update(t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = trackingTouch, touches.contains(t) else { return }
        update(t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        guard let t = trackingTouch, touches.contains(t) else { return }
        trackingTouch = nil
        vector = .zero
        UIView.animate(withDuration: 0.10) {
            self.knobView.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        }
    }

    private func update(_ point: CGPoint) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let maxRadius = bounds.width * 0.34
        let length = max(0.001, sqrt(dx * dx + dy * dy))
        let scale = min(1, maxRadius / length)
        let cx = dx * scale
        let cy = dy * scale
        knobView.center = CGPoint(x: center.x + cx, y: center.y + cy)
        vector = SIMD2(Float(cx / maxRadius), Float(-cy / maxRadius))
    }
}
