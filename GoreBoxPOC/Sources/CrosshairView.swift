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
        let c = CGPoint(x: rect.midX, y: rect.midY)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
        let gap: CGFloat = 13
        let len: CGFloat = 8
        ctx.move(to: CGPoint(x: c.x - gap - len, y: c.y)); ctx.addLine(to: CGPoint(x: c.x - gap, y: c.y))
        ctx.move(to: CGPoint(x: c.x + gap, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + gap + len, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - gap - len)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - gap))
        ctx.move(to: CGPoint(x: c.x, y: c.y + gap)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + gap + len))
        ctx.strokePath()
    }
}
