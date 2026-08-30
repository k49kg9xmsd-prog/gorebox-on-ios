import UIKit

final class HoldButton: UIControl {
    private let titleLabelView = UILabel()
    var onPressChanged: ((Bool) -> Void)?
    private(set) var isPressed = false

    init(title: String, fontSize: CGFloat = 14) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.18)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.74).cgColor
        titleLabelView.text = title
        titleLabelView.textAlignment = .center
        titleLabelView.font = .systemFont(ofSize: fontSize, weight: .bold)
        titleLabelView.textColor = UIColor.white.withAlphaComponent(0.94)
        titleLabelView.adjustsFontSizeToFitWidth = true
        titleLabelView.minimumScaleFactor = 0.55
        titleLabelView.isUserInteractionEnabled = false
        addSubview(titleLabelView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        titleLabelView.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        setPressed(true)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let inside = bounds.insetBy(dx: -28, dy: -28).contains(touch.location(in: self))
        setPressed(inside)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { setPressed(false) }
    override func cancelTracking(with event: UIEvent?) { setPressed(false) }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        alpha = pressed ? 0.55 : 1
        transform = pressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        onPressChanged?(pressed)
    }
}
