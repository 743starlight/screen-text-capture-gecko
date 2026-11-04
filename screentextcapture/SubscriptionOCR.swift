import Foundation

enum SubscriptionOCR {
    // app-server empty environments is experimental. Fail closed on older clients.
    static let minimumCodex = [0, 142, 5]
    static let minimumClaude = [2, 1, 112]

    // CLIは自動で更新されうるため、認識のたびに版と「空のenvironmentsで環境を無効にできるか」を確かめて、満たさなければ送信前に止める。
    // ログインの確認は認識に使う接続のaccount/readで1回だけ行う（確認用にapp-serverを別に起動すると、毎回の認識が数秒遅れていた）
    static func verifyCodexClient(settings: OCRSettings, workspace: URL, cancellation: Cancellation) throws {
        let version = try CLIProcess.run(path: settings.codexPath, arguments: ["--version"], workspace: workspace, cancellation: cancellation)
        guard versionAtLeast(version, minimum: minimumCodex) else { throw OCRError.unsupportedCLI("Codex CLI") }
        try verifyEnvironmentSchema(path: settings.codexPath, workspace: workspace, cancellation: cancellation)
    }

    static func verifyClaudeAccount(_ status: String) throws {
        guard let value = try? JSONSerialization.jsonObject(with: Data(status.utf8)),
              let object = value as? [String: Any] else { throw OCRError.invalidResponse }
        guard object["loggedIn"] as? Bool == true,
              ["claude.ai", "oauth"].contains(object["authMethod"] as? String ?? ""),
              object["apiProvider"] as? String == "firstParty" else { throw OCRError.loginRequired("Claude Code") }
    }

    static func verifyEnvironmentSchema(path: String, workspace: URL, cancellation: Cancellation) throws {
        let directory = workspace.appendingPathComponent("cli-schema", isDirectory: true)
        _ = try CLIProcess.run(path: path, arguments: ["app-server", "generate-json-schema", "--experimental", "--out", directory.path],
                               workspace: workspace, cancellation: cancellation)
        for name in ["ThreadStartParams", "TurnStartParams"] {
            let data = try Data(contentsOf: directory.appendingPathComponent("v2/\(name).json"))
            guard let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let properties = schema["properties"] as? [String: Any],
                  let environments = properties["environments"] as? [String: Any],
                  let description = environments["description"] as? String,
                  description.lowercased().contains("empty disables") else { throw OCRError.unsupportedCLI("Codex CLI") }
        }
    }

    static func versionAtLeast(_ text: String, minimum: [Int]) -> Bool {
        let pattern = #"\d+\.\d+\.\d+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return false }
        let actual = text[range].split(separator: ".").compactMap { Int($0) }
        return !actual.lexicographicallyPrecedes(minimum)
    }

    static func recognize(settings: OCRSettings, workspace: OCRWorkspace, cancellation: Cancellation) throws -> String {
        try cancellation.check()
        switch settings.backend {
        case .vision: return try VisionOCR.recognize(image: workspace.image, languages: settings.languages)
        case .codex:
            try verifyCodexClient(settings: settings, workspace: workspace.directory, cancellation: cancellation)
            let session = try CodexSession(settings: settings, workspace: workspace.directory, cancellation: cancellation)
            defer { session.close() }
            try session.verifyAccount()
            return try session.recognize(image: workspace.image)
        // 版・ログイン・モデルの確認は claude() の中の ModelDiscovery.discover が行うため、ここで重ねて確かめない
        case .claude: return try claude(settings: settings, workspace: workspace, cancellation: cancellation)
        }
    }

    static var claudeArguments: [String] {
        ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
         "--setting-sources", "", "--settings", "{\"disableAllHooks\":true,\"fastMode\":false,\"enableAllProjectMcpServers\":false}",
         "--disable-slash-commands", "--no-chrome", "--no-session-persistence", "--permission-mode", "dontAsk"]
    }

    static func claudeInput(image: Data, prompt: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": [
            ["type": "text", "text": prompt],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.base64EncodedString()]]
        ]], "parent_tool_use_id": NSNull()]
    }

    private static func claude(settings: OCRSettings, workspace: OCRWorkspace, cancellation: Cancellation) throws -> String {
        let discovery = try ModelDiscovery.discover(settings: settings, workspace: workspace.directory, cancellation: cancellation)
        let model = try discovery.selected(settings.modelChoice)
        try ModelDiscovery.validateFast(settings: settings, model: model, supported: discovery.fastSupported)
        var arguments = claudeArguments + ["--system-prompt", settings.prompt]
        if !settings.modelChoice.isEmpty { arguments += ["--model", model.id] }
        // Explicit false prevents the CLI's saved preference from enabling paid Fast accidentally.
        if let index = arguments.firstIndex(of: "--settings") {
            arguments[index + 1] = "{\"disableAllHooks\":true,\"fastMode\":\(settings.fastMode),\"enableAllProjectMcpServers\":false}"
        }
        let child = try CLIProcess(path: settings.cliPath, arguments: arguments,
                                   workspace: workspace.directory, timeout: settings.timeout, cancellation: cancellation)
        defer { child.stop() }
        try child.send(claudeInput(image: Data(contentsOf: workspace.image), prompt: settings.prompt))
        child.closeInput()
        var result: String?
        while let event = try child.nextJSON() {
            if let system = event["type"] as? String, system == "system", event["subtype"] as? String == "init",
               let tools = event["tools"] as? [String], !tools.isEmpty { throw OCRError.invalidResponse }
            if event["type"] as? String == "result" {
                result = try parseClaudeResult(event)
            }
        }
        guard try child.finish() == 0 else { throw child.classifiedError(name: "Claude Code") }
        guard let result else { throw OCRError.invalidResponse }
        return try OCRResult.validated(result)
    }

    static func parseClaudeResult(_ event: [String: Any]) throws -> String {
        if event["is_error"] as? Bool == true {
            let messages = (event["errors"] as? [String] ?? []).joined(separator: " ") + (event["result"] as? String ?? "")
            throw CLIProcess.classify(messages, name: "Claude Code")
        }
        guard event["subtype"] as? String == "success", let result = event["result"] as? String else { throw OCRError.invalidResponse }
        return result
    }
}

/// Uses the official CLI's JSON-RPC transport. Authentication stays inside the unmodified CLI.
/// Empty environments remove filesystem/command tools, including apply_patch and view_image.
final class CodexSession {
    private let child: CLIProcess
    private let settings: OCRSettings
    private let workspace: URL
    private var nextID = 0

    static var arguments: [String] {
        var result = ["app-server", "--listen", "stdio://", "--strict-config"]
        let overrides = ["model_provider=\"openai\"", "mcp_servers={}", "plugins={}", "apps={}", "web_search=\"disabled\"",
                         "project_doc_max_bytes=0",
                         "tools.experimental_request_user_input.enabled=false",
                         "analytics.enabled=false", "feedback.enabled=false"]
        for value in overrides { result += ["-c", value] }
        result += ["--enable", "fast_mode"]
        for feature in ["apps", "plugins", "hooks", "shell_tool", "unified_exec",
                        "multi_agent", "multi_agent_v2", "browser_use",
                        "computer_use", "image_generation", "workspace_dependencies", "memories", "shell_snapshot"] {
            result += ["--disable", feature]
        }
        return result
    }

    init(settings: OCRSettings, workspace: URL, cancellation: Cancellation) throws {
        self.settings = settings
        self.workspace = workspace
        child = try CLIProcess(path: settings.codexPath, arguments: Self.arguments, workspace: workspace,
                               timeout: settings.timeout, cancellation: cancellation)
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "screentextcapture", "version": "1.0.0"],
                                                   "capabilities": ["experimentalApi": true]])
            try child.send(["method": "initialized"])
        } catch { child.stop(); throw error }
    }

    func close() { child.stop() }

    private func readEvent() throws -> [String: Any] {
        guard let event = try child.nextJSON() else { throw child.classifiedError(name: "Codex CLI") }
        // All server-initiated tool/approval requests fail closed. No approvals are granted by this app.
        if event["method"] != nil, event["id"] != nil { throw OCRError.invalidResponse }
        return event
    }

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try child.send(["id": id, "method": method, "params": params])
        while true {
            let event = try readEvent()
            if event["id"] as? Int == id {
                if let error = event["error"] as? [String: Any] {
                    throw CLIProcess.classify(error["message"] as? String ?? "", name: "Codex CLI")
                }
                guard let result = event["result"] as? [String: Any] else { throw OCRError.invalidResponse }
                return result
            }
        }
    }

    func verifyAccount() throws {
        let result = try request("account/read", params: ["refreshToken": false])
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw OCRError.loginRequired("Codex CLI")
        }
    }

    func recognize(image: URL) throws -> String {
        let available = try models()
        let discovery = BackendDiscovery(status: "", models: available, fastSupported: true, fastReason: "")
        let selected = try discovery.selected(settings.modelChoice)
        try ModelDiscovery.validateFast(settings: settings, model: selected, supported: true)
        var params = Self.threadParameters(prompt: settings.prompt, workspace: workspace)
        params["model"] = selected.id
        if settings.fastMode { params["serviceTier"] = selected.fastTier } else { params["serviceTier"] = NSNull() }
        let started = try request("thread/start", params: params)
        guard let thread = started["thread"] as? [String: Any], let id = thread["id"] as? String else { throw OCRError.invalidResponse }
        // 0.142.5 honors empty environments but omits the response field. The request schema is checked before use.
        if let environmentValue = thread["environments"] {
            guard let environments = environmentValue as? [Any], environments.isEmpty else { throw OCRError.invalidResponse }
        }
        let data = try Data(contentsOf: image)
        _ = try request("turn/start", params: ["threadId": id, "environments": [], "input": [
            ["type": "text", "text": settings.prompt],
            ["type": "image", "url": "data:image/png;base64," + data.base64EncodedString()]
        ]])
        var finalText = ""
        while true {
            let event = try readEvent()
            let method = event["method"] as? String ?? ""
            let params = event["params"] as? [String: Any] ?? [:]
            if method == "item/started" || method == "item/completed" {
                if let item = params["item"] as? [String: Any], let type = item["type"] as? String {
                    guard ["userMessage", "agentMessage", "reasoning"].contains(type) else { throw OCRError.invalidResponse }
                    if method == "item/completed", type == "agentMessage", item["phase"] as? String != "commentary" {
                        finalText = item["text"] as? String ?? ""
                    }
                }
            }
            if method == "error", params["willRetry"] as? Bool != true {
                let error = params["error"] as? [String: Any] ?? [:]
                throw CLIProcess.classify(error["message"] as? String ?? "", name: "Codex CLI")
            }
            if method == "turn/completed" {
                guard let turn = params["turn"] as? [String: Any], turn["status"] as? String == "completed" else {
                    let turn = params["turn"] as? [String: Any] ?? [:]
                    let error = turn["error"] as? [String: Any] ?? [:]
                    throw CLIProcess.classify(error["message"] as? String ?? "", name: "Codex CLI")
                }
                return try OCRResult.validated(finalText)
            }
        }
    }

    func models() throws -> [OCRModel] {
        var models = [OCRModel]()
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let response = try request("model/list", params: params)
            guard let data = response["data"] as? [[String: Any]] else { throw OCRError.invalidResponse }
            models += ModelDiscovery.parseCodex(data)
            cursor = response["nextCursor"] as? String
        } while cursor != nil
        return models
    }

    static func threadParameters(prompt: String, workspace: URL) -> [String: Any] {
        ["cwd": workspace.path, "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only",
         "environments": [], "dynamicTools": [], "baseInstructions": prompt, "developerInstructions": prompt]
    }
}
