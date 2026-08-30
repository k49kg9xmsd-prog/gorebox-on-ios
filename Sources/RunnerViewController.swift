import UIKit

final class RunnerViewController: UIViewController {
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let textView = UITextView()
    private var latestReport = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GoreBox Compatibility Test"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "分享", style: .plain, target: self, action: #selector(shareReport)),
            UIBarButtonItem(title: "全部重測", style: .plain, target: self, action: #selector(runAllTests))
        ]
        configureUI()
        runAllTests()
    }

    private func configureUI() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progress = 0

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        textView.font = UIFont.monospacedSystemFont(ofSize: 11.8, weight: .regular)

        view.addSubview(statusLabel)
        view.addSubview(progress)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),

            progress.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progress.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),

            textView.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
    }

    @objc private func runAllTests() {
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        statusLabel.text = "全面測試：ELF / PT_LOAD / relocations / symbols / Android API / JIT memory…"
        progress.progress = 0
        textView.text = "Starting compatibility diagnostics…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var out: [String] = []
            out.append("GoreBoxRunner Compatibility Test 1.0.1")
            out.append("Target: GoreBox 13.7.9 Android ARM64")
            out.append("Host: iOS")
            out.append("Mode: comprehensive SAFE preflight")
            out.append("Guest Android code execution: NOT automatically invoked")
            out.append("")

            let jit = CompatibilityDiagnostics.jitProbe()
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("Executable / JIT memory probe")
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("RW anonymous mmap: \(jit.rwMapping ? "✅" : "❌")")
            out.append("RW → RX mprotect: \(jit.rxTransition ? "✅" : "❌")")
            out.append("MAP_JIT RWX mapping: \(jit.mapJIT ? "✅" : "❌")")
            out.append("Detail: \(jit.detail)")
            out.append("")

            var parsed = 0
            var mapped = 0
            var diagnostics: [SafeLibraryDiagnostic] = []

            let total = BinaryBundle.libraries.count
            for (index, library) in BinaryBundle.libraries.enumerated() {
                autoreleasepool {
                    do {
                        let data = try BinaryBundle.load(library)
                        let basic = ELFParser.parse(data: data, fileName: library.displayName, importedSymbolLimit: 10000)
                        if basic.validELF { parsed += 1 }
                        let diag = CompatibilityDiagnostics.analyze(data: data, basic: basic)
                        diagnostics.append(diag)
                        if diag.mapped { mapped += 1 }

                        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        out.append(library.displayName)
                        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        out.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                        out.append("ELF64/AArch64 parse: \(basic.validELF && basic.machine == "AArch64" ? "✅" : "❌")")
                        out.append("PT_LOAD segments: \(basic.loadSegmentCount)")
                        out.append("Actual anonymous segment-copy map: \(diag.mapped ? "✅" : "❌")")
                        out.append("Mapped virtual span: \(ByteCountFormatter.string(fromByteCount: Int64(min(diag.mappedSpan, UInt64(Int64.max))), countStyle: .memory))")
                        if let e = diag.mapError { out.append("Map error: \(e)") }
                        out.append("Relocations parsed: \(diag.relocationCount)")
                        if !diag.relocationTypes.isEmpty {
                            out.append("Relocation types:")
                            for (type, count) in diag.relocationTypes.prefix(12) {
                                out.append("  • \(CompatibilityDiagnostics.relocationName(type)) [\(type)]: \(count)")
                            }
                        }
                        out.append("")
                        out.append("Undefined/imported symbols: \(diag.totalImports)")
                        out.append("Directly resolvable from iOS/Darwin process: \(diag.hostResolved)/\(diag.totalImports) (\(diag.hostCoveragePercent)%)")
                        out.append("Still unresolved: \(diag.unresolved.count)")
                        out.append("  Android liblog: \(diag.androidLog.count)")
                        out.append("  Android native/window/looper/sensor: \(diag.androidNative.count)")
                        out.append("  EGL: \(diag.egl.count)")
                        out.append("  Bionic-specific ABI: \(diag.bionic.count)")
                        if !diag.bundledDependencyNames.isEmpty {
                            out.append("Bundled DT_NEEDED available in Runner: \(diag.bundledDependencyNames.joined(separator: ", "))")
                        }
                        if !diag.otherNeededLibraries.isEmpty {
                            out.append("Android-only DT_NEEDED still requiring compatibility: \(diag.otherNeededLibraries.joined(separator: ", "))")
                        }

                        self.appendSample(title: "Android native API sample", values: diag.androidNative, to: &out)
                        self.appendSample(title: "EGL sample", values: diag.egl, to: &out)
                        self.appendSample(title: "Bionic sample", values: diag.bionic, to: &out)

                        let classified = Set(diag.androidLog + diag.androidNative + diag.egl + diag.bionic)
                        let unknown = diag.unresolved.filter { !classified.contains($0) }
                        self.appendSample(title: "Other unresolved sample", values: unknown, to: &out)
                        out.append("")
                        out.append(CompatibilityDiagnostics.executionGateText(diag, jit: jit))
                        out.append("")
                    } catch {
                        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        out.append(library.displayName)
                        out.append("❌ ERROR: \(error.localizedDescription)")
                        out.append("")
                    }
                }

                DispatchQueue.main.async {
                    self.progress.progress = Float(index + 1) / Float(total)
                    self.statusLabel.text = "測試中：\(index + 1)/\(total) libraries"
                }
            }

            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("Dependency / execution strategy verdict")
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("ELF parsed: \(parsed)/\(total)")
            out.append("PT_LOAD memory-copy mapping: \(mapped)/\(total)")
            out.append("Executable-memory probe: \((jit.mapJIT || jit.rxTransition) ? "✅ available" : "❌ unavailable in current launch context")")
            out.append("")

            if let main = diagnostics.first(where: { $0.name == "libmain.so" }) {
                out.append("libmain.so host symbol coverage: \(main.hostCoveragePercent)% — first execution candidate")
            }
            if let rf = diagnostics.first(where: { $0.name == "libRF_CNative_andr.so" }) {
                out.append("RayFire host symbol coverage: \(rf.hostCoveragePercent)% — useful native-code compatibility candidate")
            }
            if let il2cpp = diagnostics.first(where: { $0.name == "libil2cpp.so" }) {
                out.append("libil2cpp host symbol coverage: \(il2cpp.hostCoveragePercent)%")
            }
            if let unity = diagnostics.first(where: { $0.name == "libunity.so" }) {
                out.append("libunity host symbol coverage: \(unity.hostCoveragePercent)%")
                out.append("Unity Android blockers: EGL=\(unity.egl.count), Android native=\(unity.androidNative.count), Bionic=\(unity.bionic.count)")
            }

            out.append("")
            out.append("What this test proves:")
            out.append("  ✅ Original GoreBox Android ARM64 objects are readable on iOS")
            out.append("  ✅ PT_LOAD regions can be represented/copied in iOS memory if all mapping tests passed")
            out.append("  ✅ Relocation workload and import coverage are now measured instead of guessed")
            out.append("  ✅ Current launch context's executable/JIT memory capability is measured")
            out.append("  ⚠️ This build intentionally does not jump into unresolved Android code; a crash would destroy the remaining diagnostics")
            out.append("")
            out.append("Next implementation target after this report:")
            out.append("  1. real symbol shim table + Bionic adapters")
            out.append("  2. relocation patcher for RELATIVE/GLOB_DAT/JUMP_SLOT")
            out.append("  3. controlled libmain/RayFire guest-call probe")
            out.append("  4. ANativeWindow + EGL bridge for libunity")

            let report = out.joined(separator: "\n")
            DispatchQueue.main.async {
                self.latestReport = report
                self.textView.text = report
                self.progress.progress = 1
                self.statusLabel.text = "全面診斷完成：ELF \(parsed)/\(total)，PT_LOAD \(mapped)/\(total)。"
                self.navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
            }
        }
    }

    private func appendSample(title: String, values: [String], to out: inout [String], limit: Int = 18) {
        guard !values.isEmpty else { return }
        out.append("\(title) (first \(min(values.count, limit))):")
        for v in values.prefix(limit) { out.append("  • \(v)") }
    }

    @objc private func shareReport() {
        guard !latestReport.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GoreBoxRunner_CompatibilityTest_1_0_1.txt")
        do {
            try latestReport.write(to: file, atomically: true, encoding: .utf8)
            let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let pop = vc.popoverPresentationController { pop.barButtonItem = navigationItem.rightBarButtonItems?.first }
            present(vc, animated: true)
        } catch {
            let alert = UIAlertController(title: "無法分享", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
