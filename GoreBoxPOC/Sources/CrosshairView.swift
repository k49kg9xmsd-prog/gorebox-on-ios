import UIKit

final class CrosshairView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let gap: CGFloat = 4
        let len: CGFloat = 9
        ctx.move(to: CGPoint(x: c.x - gap - len, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - gap, y: c.y))
        ctx.move(to: CGPoint(x: c.x + gap, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + gap + len, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - gap - len))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y - gap))
        ctx.move(to: CGPoint(x: c.x, y: c.y + gap))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + gap + len))
        ctx.strokePath()
    }
}
