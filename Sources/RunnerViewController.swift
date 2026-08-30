import UIKit

final class RunnerViewController: UIViewController {
    private let textView = UITextView()
    private let statusLabel = UILabel()
    private var latestReport = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GoreBoxRunner Stage 0"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "分享", style: .plain, target: self, action: #selector(shareReport)),
            UIBarButtonItem(title: "重掃", style: .plain, target: self, action: #selector(scanAgain))
        ]
        configureUI()
        scanAgain()
    }

    private func configureUI() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        textView.font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        view.addSubview(statusLabel)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),

            textView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
    }

    @objc private func scanAgain() {
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        statusLabel.text = "讀取 GoreBox 13.7.9 ARM64 libraries… Stage 0 不執行 guest code，也不需要 JIT。"
        textView.text = "Scanning…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var chunks: [String] = []
            chunks.append("GoreBoxRunner Stage 0 — Android ARM64 ELF inspection")
            chunks.append("Target: GoreBox 13.7.9")
            chunks.append("Host: iOS")
            chunks.append("Execution/JIT: NOT USED in Stage 0")
            chunks.append("")

            var success = 0
            for library in BinaryBundle.libraries {
                autoreleasepool {
                    do {
                        let data = try BinaryBundle.load(library)
                        let report = ELFParser.parse(data: data, fileName: library.displayName)
                        chunks.append(report.formatted)
                        chunks.append("")
                        if report.validELF { success += 1 }
                    } catch {
                        chunks.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        chunks.append(library.displayName)
                        chunks.append("❌ ERROR: \(error.localizedDescription)")
                        chunks.append("")
                    }
                }
            }

            chunks.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            chunks.append("Stage 0 verdict")
            chunks.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            if success == BinaryBundle.libraries.count {
                chunks.append("✅ All three GoreBox Android ARM64 ELF files were parsed on iOS.")
                chunks.append("Next target: Stage 1 memory mapper + relocation resolver + Android symbol shims.")
            } else {
                chunks.append("⚠️ Parsed \(success)/\(BinaryBundle.libraries.count) libraries. Fix resource/parser failures before Stage 1.")
            }

            let text = chunks.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self else { return }
                self.latestReport = text
                self.textView.text = text
                self.statusLabel.text = success == BinaryBundle.libraries.count
                    ? "Stage 0 完成：3/3 ELF 已解析。"
                    : "Stage 0：只成功 \(success)/\(BinaryBundle.libraries.count)。"
                self.navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
            }
        }
    }

    @objc private func shareReport() {
        guard !latestReport.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GoreBoxRunner_Stage0_Report.txt")
        do {
            try latestReport.write(to: file, atomically: true, encoding: .utf8)
            let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.barButtonItem = navigationItem.rightBarButtonItems?.first
            }
            present(vc, animated: true)
        } catch {
            let alert = UIAlertController(title: "無法分享", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
