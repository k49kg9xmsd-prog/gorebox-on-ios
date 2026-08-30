import UIKit

final class HUDIconButton: UIControl {
    private let glyph = UILabel()
    var onTap: (() -> Void)?
    var circular = false

    init(glyph: String, fontSize: CGFloat = 28, circular: Bool = false) {
        self.circular = circular
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(circular ? 0.18 : 0.08)
        layer.borderWidth = circular ? 1.5 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.72).cgColor
        self.glyph.text = glyph
        self.glyph.textColor = UIColor.white.withAlphaComponent(0.92)
        self.glyph.font = .systemFont(ofSize: fontSize, weight: .bold)
        self.glyph.textAlignment = .center
        self.glyph.adjustsFontSizeToFitWidth = true
        self.glyph.minimumScaleFactor = 0.55
        self.glyph.isUserInteractionEnabled = false
        addSubview(self.glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds.insetBy(dx: 5, dy: 5)
        layer.cornerRadius = circular ? bounds.width / 2 : 8
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        alpha = 0.55
        transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        alpha = 1
        transform = .identity
        if let t = touch, bounds.insetBy(dx: -14, dy: -14).contains(t.location(in: self)) { onTap?() }
    }

    override func cancelTracking(with event: UIEvent?) {
        alpha = 1
        transform = .identity
    }
}
