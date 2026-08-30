import UIKit

final class SpawnMenuView: UIView {
    var onSpawnCrate: (() -> Void)?
    var onSpawnDummy: (() -> Void)?
    var onSpawnBarrel: (() -> Void)?
    var onSpawnBall: (() -> Void)?
    var onClearSpawned: (() -> Void)?

    private let title = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.07, alpha: 0.88)
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 12
        clipsToBounds = true

        title.text = "SPAWN MENU"
        title.textColor = UIColor.white.withAlphaComponent(0.9)
        title.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        addSubview(title)

        stack.axis = .vertical
        stack.spacing = 8
        stack.distribution = .fillEqually
        addSubview(stack)

        stack.addArrangedSubview(makeButton("CRATE", action: #selector(crate)))
        stack.addArrangedSubview(makeButton("DUMMY", action: #selector(dummy)))
        stack.addArrangedSubview(makeButton("BARREL", action: #selector(barrel)))
        stack.addArrangedSubview(makeButton("BALL", action: #selector(ball)))
        stack.addArrangedSubview(makeButton("CLEAR", action: #selector(clearAll)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 16, y: 12, width: bounds.width - 32, height: 25)
        stack.frame = CGRect(x: 12, y: 48, width: bounds.width - 24, height: bounds.height - 60)
    }

    private func makeButton(_ text: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        b.layer.cornerRadius = 7
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func crate() { onSpawnCrate?() }
    @objc private func dummy() { onSpawnDummy?() }
    @objc private func barrel() { onSpawnBarrel?() }
    @objc private func ball() { onSpawnBall?() }
    @objc private func clearAll() { onClearSpawned?() }
}
