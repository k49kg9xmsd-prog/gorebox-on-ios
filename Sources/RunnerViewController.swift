import UIKit
import UniformTypeIdentifiers

final class RunnerViewController: UIViewController, UIDocumentPickerDelegate {
    private let profileLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let importButton = UIButton(type: .system)
    private let diagnosticsButton = UIButton(type: .system)
    private let guestProbeButton = UIButton(type: .system)
    private let removeButton = UIButton(type: .system)
    private let textView = UITextView()
    private var latestReport = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GoreBoxRunner"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "分享", style: .plain, target: self, action: #selector(shareReport))
        configureUI()
        refreshInstalledState()
        if UserDefaults.standard.bool(forKey: "RayFireProbePending") {
            UserDefaults.standard.set(false, forKey: "RayFireProbePending")
            showMessage(title: "上一個 ARM64 Probe 未完成", message: "上次執行 RayFire guest-call 後 App 沒有回寫成功標記，可能是在 anonymous executable memory 或 guest code 跳轉時被 iOS 終止。")
        }
    }

    private func configureUI() {
        profileLabel.font = .systemFont(ofSize: 22, weight: .bold)
        profileLabel.numberOfLines = 0
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        progress.isHidden = true

        styleButton(importButton, title: "匯入 GoreBox APK", action: #selector(importAPK))
        styleButton(diagnosticsButton, title: "全面相容性診斷", action: #selector(runDiagnostics))
        styleButton(guestProbeButton, title: "RayFire ARM64 真執行測試", action: #selector(runGuestProbe))
        styleButton(removeButton, title: "移除已匯入遊戲", action: #selector(removeGame))
        removeButton.tintColor = .systemRed

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let stack = UIStackView(arrangedSubviews: [profileLabel, detailLabel, progress, importButton, diagnosticsButton, guestProbeButton, removeButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    private func styleButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .medium
        config.buttonSize = .large
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func refreshInstalledState() {
        let installed = ImportedGame.isInstalled()
        diagnosticsButton.isEnabled = installed
        guestProbeButton.isEnabled = installed
        removeButton.isEnabled = installed
        if installed, let meta = ImportedGame.metadata() {
            profileLabel.text = meta.profile
            detailLabel.text = "APK 已倒入並保存在 App 資料中\nSHA256: \(meta.sha256.prefix(20))…\nARM64 libraries: 4/4\nIL2CPP metadata: \(FileManager.default.fileExists(atPath: ImportedGame.metadataURL.path) ? "✅" : "❌")"
            textView.text = "遊戲已安裝。\n\n可以先按「全面相容性診斷」，或按 RayFire ARM64 真執行測試。\n\n注意：GoreBox 完整啟動仍需要我們後續完成 Bionic / JNI / ANativeWindow / EGL 相容層。"
        } else {
            profileLabel.text = "No game installed"
            detailLabel.text = "先從 iOS「檔案」選擇你的 GoreBox APK。Runner 不內建遊戲本體。"
            textView.text = "1. 點「匯入 GoreBox APK」\n2. 選 GoreBox_v13.7.9.apk\n3. Runner 會保存 APK，並抽出 ARM64 Unity / IL2CPP / RayFire runtime\n4. 之後不用每次重新匯入"
        }
    }

    @objc private func importAPK() {
        let apkType = UTType(filenameExtension: "apk") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [apkType, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        progress.isHidden = false
        progress.progress = 0
        setButtons(enabled: false)
        profileLabel.text = "Importing…"
        detailLabel.text = url.lastPathComponent
        textView.text = "Preparing APK import…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let info = try ImportedGame.importAPK(from: url) { message, value in
                    DispatchQueue.main.async {
                        self.progress.progress = Float(value)
                        self.textView.text = message
                    }
                }
                DispatchQueue.main.async {
                    self.progress.isHidden = true
                    self.setButtons(enabled: true)
                    self.refreshInstalledState()
                    self.showMessage(title: "匯入完成 😆", message: "\(info.profile)\n\n4 顆 Android ARM64 library 與 IL2CPP metadata 已抽出；原 APK 也已保存，後面可以直接從它讀 Unity assets。")
                }
            } catch {
                DispatchQueue.main.async {
                    self.progress.isHidden = true
                    self.setButtons(enabled: true)
                    self.refreshInstalledState()
                    self.showMessage(title: "匯入失敗", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func runDiagnostics() {
        guard ImportedGame.isInstalled() else { return }
        setButtons(enabled: false)
        progress.isHidden = false
        progress.progress = 0
        textView.text = "Starting imported-APK diagnostics…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var out: [String] = []
            let meta = ImportedGame.metadata()
            out.append("GoreBoxRunner APK Import Runtime 0.1")
            out.append("Profile: \(meta?.profile ?? "unknown")")
            out.append("APK SHA256: \(meta?.sha256 ?? "unknown")")
            out.append("Host: iOS")
            out.append("")
            let jit = CompatibilityDiagnostics.jitProbe()
            out.append("Executable memory: RW mmap=\(jit.rwMapping ? "✅" : "❌"), RW→RX=\(jit.rxTransition ? "✅" : "❌"), MAP_JIT=\(jit.mapJIT ? "✅" : "❌")")
            out.append("Detail: \(jit.detail)")
            out.append("")
            var parsed = 0
            var mapped = 0
            let libs = ImportedGame.requiredLibraries
            for (index, lib) in libs.enumerated() {
                autoreleasepool {
                    do {
                        let data = try ImportedGame.load(lib)
                        let basic = ELFParser.parse(data: data, fileName: lib.fileName, importedSymbolLimit: 10000)
                        let diag = CompatibilityDiagnostics.analyze(data: data, basic: basic)
                        if basic.validELF { parsed += 1 }
                        if diag.mapped { mapped += 1 }
                        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        out.append(lib.fileName)
                        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        out.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                        out.append("ELF64/AArch64: \(basic.validELF && basic.machine == "AArch64" ? "✅" : "❌")")
                        out.append("PT_LOAD map: \(diag.mapped ? "✅" : "❌")")
                        out.append("Relocations: \(diag.relocationCount)")
                        out.append("Host symbol coverage: \(diag.hostResolved)/\(diag.totalImports) (\(diag.hostCoveragePercent)%)")
                        out.append("Unresolved: \(diag.unresolved.count) | Android=\(diag.androidNative.count) | EGL=\(diag.egl.count) | Bionic=\(diag.bionic.count) | liblog=\(diag.androidLog.count)")
                        out.append(CompatibilityDiagnostics.executionGateText(diag, jit: jit))
                        out.append("")
                    } catch {
                        out.append("\(lib.fileName): ❌ \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.async { self.progress.progress = Float(index + 1) / Float(libs.count) }
            }
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("Result")
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("ELF parsed: \(parsed)/4")
            out.append("PT_LOAD mapped: \(mapped)/4")
            out.append("APK import/runtime storage: ✅")
            out.append("Full GoreBox launch: still requires Android compatibility bridge")
            let report = out.joined(separator: "\n")
            DispatchQueue.main.async {
                self.latestReport = report
                self.textView.text = report
                self.progress.isHidden = true
                self.setButtons(enabled: true)
            }
        }
    }

    @objc private func runGuestProbe() {
        let alert = UIAlertController(title: "RayFire ARM64 真執行測試", message: "這會把 APK 裡 RayFire 的原 Android ARM64 `ret` 指令映射成 RX 並直接跳進去。\n\n如果目前的 iOS/LiveContainer 執行環境阻止 anonymous executable code，App 可能會直接被系統關掉。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "執行", style: .destructive) { [weak self] _ in self?.performGuestProbe() })
        present(alert, animated: true)
    }

    private func performGuestProbe() {
        UserDefaults.standard.set(true, forKey: "RayFireProbePending")
        UserDefaults.standard.synchronize()
        do {
            try GuestProbe.runRayFireSafeReturn()
            UserDefaults.standard.set(false, forKey: "RayFireProbePending")
            textView.text = "✅ RayFire guest-call returned successfully.\n\nThis iOS process executed an ARM64 instruction copied directly from GoreBox's Android libRF_CNative_andr.so and safely returned to iOS."
            showMessage(title: "ARM64 Guest Code 成功 😆", message: "RayFire Android ARM64 machine code 已真的在 iOS process 裡執行並返回。下一步就可以開始做 relocation + shim，而不是只做解析。")
        } catch {
            UserDefaults.standard.set(false, forKey: "RayFireProbePending")
            showMessage(title: "Probe 未執行", message: error.localizedDescription)
        }
    }

    @objc private func removeGame() {
        let alert = UIAlertController(title: "移除 GoreBox？", message: "會刪除 Runner 保存的 APK 與抽出的 runtime。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            try? ImportedGame.removeInstall()
            self?.latestReport = ""
            self?.refreshInstalledState()
        })
        present(alert, animated: true)
    }

    private func setButtons(enabled: Bool) {
        importButton.isEnabled = enabled
        diagnosticsButton.isEnabled = enabled && ImportedGame.isInstalled()
        guestProbeButton.isEnabled = enabled && ImportedGame.isInstalled()
        removeButton.isEnabled = enabled && ImportedGame.isInstalled()
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func shareReport() {
        guard !latestReport.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GoreBoxRunner_Report.txt")
        do {
            try latestReport.write(to: file, atomically: true, encoding: .utf8)
            let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let pop = vc.popoverPresentationController { pop.barButtonItem = navigationItem.rightBarButtonItem }
            present(vc, animated: true)
        } catch { showMessage(title: "無法分享", message: error.localizedDescription) }
    }
}
