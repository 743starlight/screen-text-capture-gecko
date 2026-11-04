import Foundation

struct OCRModel: Identifiable, Equatable {
    let id: String
    let name: String
    var isDefault = false
    var fastTier: String?
}

struct BackendDiscovery {
    let status: String
    let models: [OCRModel]
    let fastSupported: Bool
    let fastReason: String

    func selected(_ id: String) throws -> OCRModel {
        let selected = id.isEmpty ? (models.first(where: \.isDefault) ?? models.first) : models.first(where: { $0.id == id })
        guard let selected else { throw OCRError.unavailableModel }
        return selected
    }
}

enum ModelDiscovery {
    static func discover(settings: OCRSettings, workspace: URL, cancellation: Cancellation = Cancellation(),
                         progress: (String) -> Void = { _ in }) throws -> BackendDiscovery {
        try cancellation.check()
        if settings.backend == .vision {
            progress("認識言語を確認しています…")
            try VisionOCR.validateLanguages(settings.languages)
            return BackendDiscovery(status: "利用できます。選択した認識言語に対応しています。", models: [], fastSupported: false,
                                    fastReason: "")
        }
        progress("CLIのパス・バージョンを確認しています…")
        let name = settings.backend == .codex ? "Codex CLI" : "Claude Code"
        let version = try CLIProcess.run(path: settings.cliPath, arguments: ["--version"], workspace: workspace,
                                        timeout: 8, cancellation: cancellation).trimmingCharacters(in: .whitespacesAndNewlines)
        let minimum = settings.backend == .codex ? SubscriptionOCR.minimumCodex : SubscriptionOCR.minimumClaude
        guard SubscriptionOCR.versionAtLeast(version, minimum: minimum) else { throw OCRError.unsupportedCLI(name) }
        switch settings.backend {
        case .vision:
            preconditionFailure("Vision is handled before launching a CLI")
        case .codex:
            progress("CLIの画像入力対応を確認しています…")
            try SubscriptionOCR.verifyEnvironmentSchema(path: settings.codexPath, workspace: workspace, cancellation: cancellation)
            var sessionSettings = settings
            sessionSettings.timeout = 15
            let session = try CodexSession(settings: sessionSettings, workspace: workspace, cancellation: cancellation)
            defer { session.close() }
            progress("ChatGPTのログイン状態を確認しています…")
            try session.verifyAccount()
            progress("画像対応モデルを取得しています…")
            let models = try session.models()
            guard !models.isEmpty else { throw OCRError.unavailableModel }
            return BackendDiscovery(status: "\(version)：ChatGPTログイン確認済み・画像対応モデル\(models.count)件。", models: models,
                                    fastSupported: models.contains { $0.fastTier != nil }, fastReason: "")
        case .claude:
            progress("Claudeのログイン状態を確認しています…")
            let account = try CLIProcess.run(path: settings.claudePath, arguments: ["auth", "status"], workspace: workspace,
                                             timeout: 8, cancellation: cancellation, allowedExitCodes: [0, 1])
            try SubscriptionOCR.verifyClaudeAccount(account)
            progress("モデル候補を取得しています…")
            let child = try CLIProcess(path: settings.claudePath,
                                       arguments: SubscriptionOCR.claudeArguments + ["--system-prompt", settings.prompt],
                                       workspace: workspace, timeout: 15, cancellation: cancellation)
            defer { child.stop() }
            try child.send(["type": "control_request", "request_id": "models", "request": ["subtype": "initialize", "hooks": NSNull(), "skills": []]])
            while let event = try child.nextJSON() {
                guard event["type"] as? String == "control_response",
                      let response = event["response"] as? [String: Any], response["request_id"] as? String == "models" else { continue }
                guard response["subtype"] as? String == "success", let info = response["response"] as? [String: Any] else {
                    throw OCRError.invalidResponse
                }
                let models = parseClaude(info)
                guard !models.isEmpty else { throw OCRError.unavailableModel }
                let fast = SubscriptionOCR.versionAtLeast(version, minimum: [2, 1, 205])
                return BackendDiscovery(status: "\(version)：Claudeログイン確認済み・モデル候補\(models.count)件。", models: models,
                                        fastSupported: fast, fastReason: fast ? "" : "FastはClaude Code 2.1.205以上で利用できます。")
            }
            throw OCRError.invalidResponse
        }
    }

    static func parseCodex(_ data: [[String: Any]]) -> [OCRModel] {
        data.compactMap { value in
            guard value["hidden"] as? Bool != true,
                  (value["inputModalities"] as? [String] ?? []).contains("image"),
                  let id = value["model"] as? String ?? value["id"] as? String else { return nil }
            let tiers = value["serviceTiers"] as? [[String: Any]] ?? []
            let fast = tiers.first { ($0["id"] as? String) == "fast" || ($0["name"] as? String)?.lowercased() == "fast" }?["id"] as? String
            return OCRModel(id: id, name: value["displayName"] as? String ?? id,
                            isDefault: value["isDefault"] as? Bool ?? false, fastTier: fast)
        }
    }

    /// These options come from Claude Code's authenticated SDK initialization, never a hard-coded model list.
    static func parseClaude(_ info: [String: Any]) -> [OCRModel] {
        (info["models"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["value"] as? String ?? value["id"] as? String else { return nil }
            return OCRModel(id: id, name: value["displayName"] as? String ?? value["label"] as? String ?? id,
                            isDefault: id == "default", fastTier: id == "opus" ? "fast" : nil)
        }
    }

    static func validateFast(settings: OCRSettings, model: OCRModel, supported: Bool) throws {
        guard settings.fastMode else { return }
        guard settings.fastCostConsent else { throw OCRError.fastConsentRequired }
        guard supported, model.fastTier != nil else { throw OCRError.fastUnavailable }
    }
}
