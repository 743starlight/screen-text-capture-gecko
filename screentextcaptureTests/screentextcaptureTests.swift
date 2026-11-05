import XCTest
import AppKit
@testable import screentextcapture

final class ScreenTextCaptureTests: XCTestCase {
    func testSettingsDefaultsAreLocal() {
        let settings = OCRSettings()
        XCTAssertEqual(settings.backend, .vision)
        XCTAssertFalse(settings.cloudConsent)
        XCTAssertEqual(settings.languages, ["ja-JP", "en-US"])
        XCTAssertEqual(settings.shortcut, .defaultShortcut)
    }

    func testSettingsRoundTripAndCorruptData() throws {
        let name = "ScreenTextCaptureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = OCRSettings(); settings.backend = .claude; settings.shortcut = nil
        settings.save(to: defaults)
        XCTAssertEqual(OCRSettings.load(from: defaults), settings)
        defaults.set(Data("invalid".utf8), forKey: OCRSettings.key)
        XCTAssertEqual(OCRSettings.load(from: defaults), OCRSettings())
    }

    func testPrivateWorkspaceRemoved() throws {
        let workspace = try OCRWorkspace()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: workspace.directory.path)[.posixPermissions] as? Int), 0o700)
        try Data("test".utf8).write(to: workspace.image)
        workspace.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.directory.path))
    }

    func testInstanceLeaseRejectsDuplicateAndReleasesAfterExit() throws {
        let workspace = try OCRWorkspace()
        let path = workspace.directory.appendingPathComponent("instance.lock")
        var primary: InstanceLease? = try InstanceLease(url: path)
        XCTAssertTrue(primary?.isPrimary == true)
        XCTAssertFalse(try InstanceLease(url: path).isPrimary)
        primary = nil
        XCTAssertTrue(try InstanceLease(url: path).isPrimary)
    }

    func testPermissionPromptRejectsDuplicatesAndQueuedRepeats() {
        let prompt = PermissionPromptGate()
        let now = Date()
        XCTAssertTrue(prompt.begin(now: now))
        XCTAssertFalse(prompt.begin(now: now.addingTimeInterval(2)))
        prompt.finish(now: now.addingTimeInterval(3))
        XCTAssertFalse(prompt.begin(now: now.addingTimeInterval(3.5)))
        XCTAssertFalse(prompt.isPresented)
        XCTAssertTrue(prompt.begin(now: now.addingTimeInterval(4.1)))
    }

    func testPermissionKindsExplainDifferentRequirements() {
        XCTAssertTrue(PermissionKind.screenCapture.title.contains("画面収録"))
        XCTAssertTrue(PermissionKind.screenCapture.explanation.contains("音声の録音やアクセシビリティの許可は必要ありません"))
        XCTAssertTrue(PermissionKind.screenCapture.settingsURL.absoluteString.contains("Privacy_ScreenCapture"))
        XCTAssertTrue(PermissionKind.notifications.title.contains("通知"))
        XCTAssertTrue(PermissionKind.notifications.explanation.contains("文字のコピーは利用できます"))
        XCTAssertFalse(PermissionKind.notifications.settingsURL.absoluteString.contains("ScreenCapture"))
    }

    func testPermissionHelpDoesNotConfuseGrantedPermissions() {
        XCTAssertTrue(PermissionKind.screenCapture.isGranted(screenCapture: true, notifications: false))
        XCTAssertFalse(PermissionKind.notifications.isGranted(screenCapture: true, notifications: false))
        XCTAssertFalse(PermissionKind.screenCapture.isGranted(screenCapture: false, notifications: true))
        XCTAssertTrue(PermissionKind.notifications.isGranted(screenCapture: false, notifications: true))
    }

    func testOnlyRuntimeEnvironmentInherited() throws {
        let workspace = try OCRWorkspace()
        let env = CLIEnvironment.make(workspace: workspace.directory)
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "AWS_SECRET_ACCESS_KEY", "CODEX_HOME"] {
            XCTAssertNil(env[key])
        }
        XCTAssertEqual(env["TMPDIR"], workspace.directory.path)
        // Claude Codeはログイン情報をユーザー名で探すため、USERだけは渡す
        XCTAssertEqual(env["USER"], NSUserName())
    }

    func testPromptTreatsImageAsData() {
        XCTAssertTrue(OCRSettings().prompt.contains("untrusted data"))
        XCTAssertTrue(OCRSettings().prompt.contains("Do not use tools"))
    }

    func testClipboardSuccessAndEmptyPreservesPreviousValue() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try OCRResult.copy("日本語\nHello", to: board)
        XCTAssertEqual(board.string(forType: .string), "日本語\nHello")
        XCTAssertThrowsError(try OCRResult.copy(" \n ", to: board)) { XCTAssertEqual($0 as? OCRError, .emptyResult) }
        XCTAssertEqual(board.string(forType: .string), "日本語\nHello")
    }

    func testVisionOnSyntheticBilingualImage() throws {
        let workspace = try syntheticImage()
        let result = try VisionOCR.recognize(image: workspace.image, languages: ["ja-JP", "en-US"])
        XCTAssertTrue(result.contains("SCREEN TEXT 2026"), result)
        XCTAssertTrue(result.contains("画面の文字をコピー"), result)
    }

    func testVisionInvalidLanguageAndImage() throws {
        let workspace = try syntheticImage()
        XCTAssertThrowsError(try VisionOCR.recognize(image: workspace.image, languages: ["not-a-language"])) {
            XCTAssertEqual($0 as? OCRError, .invalidLanguage("not-a-language"))
        }
        try Data("not an image".utf8).write(to: workspace.image)
        XCTAssertThrowsError(try VisionOCR.recognize(image: workspace.image, languages: [])) {
            XCTAssertEqual($0 as? OCRError, .invalidImage)
        }
    }

    func testVisionBlankImageIsEmpty() throws {
        let workspace = try syntheticImage(text: "")
        XCTAssertThrowsError(try VisionOCR.recognize(image: workspace.image, languages: ["en-US"])) {
            XCTAssertEqual($0 as? OCRError, .emptyResult)
        }
    }

    func testProcessMissingCLI() throws {
        let workspace = try OCRWorkspace()
        XCTAssertThrowsError(try CLIProcess.run(path: "/nonexistent/codex", arguments: [], workspace: workspace.directory)) {
            XCTAssertEqual($0 as? OCRError, .missingCLI("codex"))
        }
    }

    func testProcessDrainsLargeStderrAndOutput() throws {
        let workspace = try OCRWorkspace()
        let text = try CLIProcess.run(path: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stderr.write('x'*2000000); print('complete')"], workspace: workspace.directory)
        XCTAssertEqual(text, "complete\n")
    }

    func testProcessTimeout() throws {
        let workspace = try OCRWorkspace()
        XCTAssertThrowsError(try CLIProcess.run(path: "/usr/bin/python3", arguments: ["-c", "import time; time.sleep(3)"], workspace: workspace.directory, timeout: 0.1)) {
            XCTAssertEqual($0 as? OCRError, .timeout)
        }
    }

    func testProcessCancellation() throws {
        let workspace = try OCRWorkspace()
        let cancellation = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        XCTAssertThrowsError(try CLIProcess.run(path: "/usr/bin/python3", arguments: ["-c", "import time; time.sleep(3)"], workspace: workspace.directory, cancellation: cancellation)) {
            XCTAssertEqual($0 as? OCRError, .cancelled)
        }
    }

    func testOutputLimitStopsProcess() throws {
        let workspace = try OCRWorkspace()
        let process = try CLIProcess(path: "/usr/bin/python3", arguments: ["-c", "print('x'*100000)"], workspace: workspace.directory, timeout: 5, outputLimit: 1024)
        defer { process.stop() }
        process.closeInput()
        XCTAssertThrowsError(try process.nextLine()) { XCTAssertEqual($0 as? OCRError, .outputTooLarge) }
    }

    func testAuthAndRateErrorsHaveSafeMessages() {
        XCTAssertEqual(CLIProcess.classify("401 Unauthorized token abc-secret", name: "CLI"), .loginRequired("CLI"))
        XCTAssertEqual(CLIProcess.classify("429 usage limit", name: "CLI"), .usageLimit("CLI"))
        XCTAssertFalse(OCRError.cliFailed("CLI").localizedDescription.contains("abc-secret"))
        XCTAssertThrowsError(try SubscriptionOCR.parseClaudeResult(["is_error": true, "result": "rate limit", "subtype": "error"])) {
            XCTAssertEqual($0 as? OCRError, .usageLimit("Claude Code"))
        }
    }

    func testClaudeSubscriptionAuthenticationAndAPIRejection() throws {
        XCTAssertNoThrow(try SubscriptionOCR.verifyClaudeAccount(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#))
        XCTAssertThrowsError(try SubscriptionOCR.verifyClaudeAccount(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}"#)) {
            XCTAssertEqual($0 as? OCRError, .loginRequired("Claude Code"))
        }
        XCTAssertThrowsError(try SubscriptionOCR.verifyClaudeAccount("not JSON")) { XCTAssertEqual($0 as? OCRError, .invalidResponse) }
    }

    func testClaudeImageProtocolAndToolsDisabled() throws {
        let payload = SubscriptionOCR.claudeInput(image: Data([1, 2, 3]), prompt: "OCR")
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content.last?["source"] as? [String: String])
        XCTAssertEqual(source["media_type"], "image/png")
        XCTAssertEqual(source["data"], "AQID")
        let args = SubscriptionOCR.claudeArguments
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--tools")) + 1], "")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    func testCodexHasNoEnvironmentAccess() throws {
        let workspace = try OCRWorkspace()
        let params = CodexSession.threadParameters(prompt: "OCR", workspace: workspace.directory)
        XCTAssertEqual((params["environments"] as? [String])?.count, 0)
        XCTAssertEqual((params["dynamicTools"] as? [String])?.count, 0)
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        XCTAssertTrue(CodexSession.arguments.contains("mcp_servers={}"))
    }

    func testUnsupportedVersionsFailClosed() {
        XCTAssertFalse(SubscriptionOCR.versionAtLeast("codex-cli 0.100.0", minimum: SubscriptionOCR.minimumCodex))
        XCTAssertTrue(SubscriptionOCR.versionAtLeast("codex-cli 0.142.5", minimum: SubscriptionOCR.minimumCodex))
        XCTAssertFalse(SubscriptionOCR.versionAtLeast("unknown", minimum: SubscriptionOCR.minimumClaude))
    }

    // 認識の前の確認を重ねなくなっても、未ログインのClaudeは画像を送る前に止まる
    func testClaudeLoggedOutRecognitionFailsClosed() throws {
        let workspace = try syntheticImage()
        let path = try fakeCLI(workspace: workspace, mode: "claude-logged-out")
        var settings = OCRSettings(); settings.backend = .claude; settings.claudePath = path
        XCTAssertThrowsError(try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: Cancellation())) {
            XCTAssertEqual($0 as? OCRError, .loginRequired("Claude Code"))
        }
        XCTAssertFalse(try String(contentsOfFile: path + ".calls", encoding: .utf8).contains("--print"))
    }

    // Codexの認識は版と環境を無効にできるかを確かめてから、app-serverを1回だけ起動して行う。古いスキーマなら起動前に止まる
    func testCodexRecognitionStartsOneServerAndFailsClosedOnOldSchema() throws {
        let workspace = try syntheticImage()
        var settings = OCRSettings(); settings.backend = .codex; settings.cloudConsent = true
        settings.codexPath = try fakeCLI(workspace: workspace, mode: "codex-success")
        XCTAssertEqual(try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: Cancellation()), "SCREEN TEXT 2026")
        let calls = try String(contentsOfFile: settings.codexPath + ".calls", encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.filter { $0 == "app-server --listen" }.count, 1, calls.joined(separator: " / "))
        settings.codexPath = try fakeCLI(workspace: workspace, mode: "codex-oldschema")
        XCTAssertThrowsError(try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: Cancellation())) {
            XCTAssertEqual($0 as? OCRError, .unsupportedCLI("Codex CLI"))
        }
        let oldCalls = try String(contentsOfFile: settings.codexPath + ".calls", encoding: .utf8)
        XCTAssertFalse(oldCalls.contains("app-server --listen"))
    }

    func testCodexProtocolSuccessAndRejectsToolEvents() throws {
        for mode in ["codex-success", "codex-tool", "codex-env", "codex-rate", "codex-logged-out"] {
            let workspace = try syntheticImage()
            let path = try fakeCLI(workspace: workspace, mode: mode)
            var settings = OCRSettings(); settings.backend = .codex; settings.codexPath = path
            let session = try CodexSession(settings: settings, workspace: workspace.directory, cancellation: Cancellation())
            defer { session.close() }
            if mode == "codex-logged-out" {
                XCTAssertThrowsError(try session.verifyAccount()) { XCTAssertEqual($0 as? OCRError, .loginRequired("Codex CLI")) }
                continue
            }
            try session.verifyAccount()
            if mode == "codex-success" {
                XCTAssertEqual(try session.recognize(image: workspace.image), "SCREEN TEXT 2026")
            } else if mode == "codex-rate" {
                XCTAssertThrowsError(try session.recognize(image: workspace.image)) { XCTAssertEqual($0 as? OCRError, .usageLimit("Codex CLI")) }
            } else {
                XCTAssertThrowsError(try session.recognize(image: workspace.image)) { XCTAssertEqual($0 as? OCRError, .invalidResponse) }
            }
        }
    }

    func testCodexFastUsesAdvertisedServiceTier() throws {
        let workspace = try syntheticImage()
        var settings = OCRSettings(); settings.backend = .codex
        settings.codexPath = try fakeCLI(workspace: workspace, mode: "codex-fast")
        settings.codexFast = true; settings.fastCostConsent = true
        let session = try CodexSession(settings: settings, workspace: workspace.directory, cancellation: Cancellation())
        defer { session.close() }
        try session.verifyAccount()
        XCTAssertEqual(try session.recognize(image: workspace.image), "SCREEN TEXT 2026")
    }

    func testClaudeIsolatedStreamingOCR() throws {
        let workspace = try syntheticImage()
        var settings = OCRSettings(); settings.backend = .claude; settings.claudeModel = "sonnet"
        settings.claudePath = try fakeCLI(workspace: workspace, mode: "claude-success")
        XCTAssertEqual(try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: Cancellation()), "SCREEN TEXT 2026")
    }

    func testGateRejectsRepeatedTriggersAndCancellation() {
        let gate = OperationGate()
        let first = gate.begin()
        XCTAssertNotNil(first); XCTAssertNil(gate.begin())
        gate.cancel(); XCTAssertTrue(first?.isCancelled == true)
        gate.finish(); XCTAssertNotNil(gate.begin())
    }

    func testHotkeyConflictPreservesPreviousRegistrationAndUnset() throws {
        let first = GlobalShortcut(); let second = GlobalShortcut()
        let shortcut = Shortcut(keyCode: 80, modifiers: 0x100 | 0x1000 | 0x800 | 0x200, label: "test F19")
        try first.register(shortcut)
        XCTAssertNoThrow(try first.register(Shortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, label: "same key")))
        try first.register(shortcut)
        XCTAssertThrowsError(try second.register(shortcut))
        XCTAssertEqual(first.registered, shortcut)
        XCTAssertNil(second.registered)
        try first.register(nil)
        XCTAssertNil(first.registered)
        try second.register(shortcut)
        try second.register(nil)
    }

    // 旧版は⇧を適用した記号で保存していた（⇧⌘6 → "⇧⌘^"）。保存済みの値も新しい記録も、押したキー自体を表示する
    func testShiftedShortcutShowsPressedKeyInsteadOfShiftedSymbol() throws {
        let commandShift: UInt32 = 0x100 | 0x200
        let legacy = Shortcut(keyCode: 22, modifiers: commandShift, label: "⇧⌘^")
        XCTAssertTrue(legacy.displayLabel.hasPrefix("⇧⌘"))
        XCTAssertFalse(legacy.displayLabel.contains("^"))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "^",
                                                   charactersIgnoringModifiers: "^", isARepeat: false, keyCode: 22))
        let recorded = try XCTUnwrap(Shortcut.from(event))
        XCTAssertEqual(recorded.modifiers, commandShift)
        XCTAssertFalse(recorded.label.contains("^"))
        XCTAssertEqual(recorded.label, recorded.displayLabel)
        XCTAssertEqual(Shortcut.symbols(for: 0x1000 | 0x800 | 0x200 | 0x100), "⌃⌥⇧⌘")
    }

    func testScreenPermissionDeniedWithoutRequestingIt() throws {
        if ScreenPermission.isGranted { throw XCTSkip("Screen recording is already granted; no real capture is performed.") }
        let workspace = try OCRWorkspace()
        XCTAssertThrowsError(try ScreenSelection.capture(workspace: workspace, cancellation: Cancellation())) {
            XCTAssertEqual($0 as? OCRError, .permissionDenied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.image.path))
    }

    func testModelDiscoveryFiltersImageAndFastAvailability() throws {
        let models = ModelDiscovery.parseCodex([
            ["model": "image", "displayName": "Image", "inputModalities": ["text", "image"], "isDefault": true, "serviceTiers": [["id": "priority", "name": "Fast"]]],
            ["model": "text", "inputModalities": ["text"]],
            ["model": "hidden", "inputModalities": ["image"], "hidden": true],
            ["model": "unknown"]
        ])
        XCTAssertEqual(models.map(\.id), ["image"])
        XCTAssertEqual(models[0].fastTier, "priority")
        let discovery = BackendDiscovery(status: "", models: models, fastSupported: true, fastReason: "")
        XCTAssertEqual(try discovery.selected("").id, "image")
        XCTAssertThrowsError(try discovery.selected("unavailable")) { XCTAssertEqual($0 as? OCRError, .unavailableModel) }
    }

    func testFastDefaultsAndExplicitCostConfirmation() throws {
        var settings = OCRSettings(); settings.backend = .codex
        XCTAssertFalse(settings.fastMode); XCTAssertFalse(settings.fastCostConsent)
        let fast = OCRModel(id: "image", name: "Image", fastTier: "priority")
        settings.fastMode = true
        XCTAssertThrowsError(try ModelDiscovery.validateFast(settings: settings, model: fast, supported: true)) { XCTAssertEqual($0 as? OCRError, .fastConsentRequired) }
        settings.fastCostConsent = true
        XCTAssertNoThrow(try ModelDiscovery.validateFast(settings: settings, model: fast, supported: true))
        XCTAssertThrowsError(try ModelDiscovery.validateFast(settings: settings, model: fast, supported: false)) { XCTAssertEqual($0 as? OCRError, .fastUnavailable) }
        settings.codexModel = "codex-model"; settings.claudeModel = "claude-model"
        settings.backend = .claude
        XCTAssertFalse(settings.fastMode)
        XCTAssertEqual(settings.modelChoice, "claude-model")
        settings.backend = .codex
        XCTAssertTrue(settings.fastMode)
        XCTAssertEqual(settings.modelChoice, "codex-model")
    }

    func testClaudeModelsComeFromInitialization() {
        let models = ModelDiscovery.parseClaude(["models": [["value": "opus", "displayName": "Account Opus"], ["value": "sonnet", "displayName": "Account Sonnet"]]])
        XCTAssertEqual(models.map(\.id), ["opus", "sonnet"])
        XCTAssertEqual(models.first?.fastTier, "fast")
        XCTAssertNil(models.last?.fastTier)
        XCTAssertTrue(ModelDiscovery.parseClaude([:]).isEmpty)
    }

    func testSettingsMigrationAndModelPersistence() throws {
        let legacy = Data(#"{"backend":"codex","codexPath":"/custom/codex","shortcut":null}"#.utf8)
        let settings = try JSONDecoder().decode(OCRSettings.self, from: legacy)
        XCTAssertEqual(settings.backend, .codex); XCTAssertEqual(settings.codexPath, "/custom/codex")
        XCTAssertNil(settings.shortcut); XCTAssertFalse(settings.fastMode); XCTAssertEqual(settings.copyFeedback, .toast)
        XCTAssertEqual(settings.menuBarIcon, .symbol)
        var selection = settings; selection.codexModel = "image"; selection.codexFast = true; selection.fastCostConsent = true
        selection.menuBarIcon = .gecko
        XCTAssertEqual(try JSONDecoder().decode(OCRSettings.self, from: JSONEncoder().encode(selection)), selection)
    }

    // 入口がメニューバーにしかないため、画像の欠けた選択肢があると常駐していても見つけられなくなる。
    // どの選択肢もアプリ内の画像を引け、メニューバーの明暗に追従するテンプレートであること
    func testEveryMenuBarIconChoiceHasTemplateImage() {
        for icon in MenuBarIcon.allCases {
            let image = icon.image
            XCTAssertNotNil(image, icon.rawValue)
            XCTAssertEqual(image?.isTemplate, true, icon.rawValue)
        }
    }

    // 自動アップデートの設定が欠けると、Sparkle は更新を断る（公開鍵がない・壊れている）か、どこも読まない。
    // 配信先は最新のリリースに添付した appcast で、更新は自動で確かめて入れ替える
    func testSparkleFeedAndKeyAreConfigured() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/743starlight/screen-text-capture-gecko/releases/latest/download/appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "EdDSA（ed25519）の公開鍵は32バイト")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
    }

    // アップデートで開き直した起動は手動の起動に見えるが、範囲選択を始めない。印は一度だけ効く
    func testUpdateRelaunchMarkIsConsumedOnce() throws {
        let name = "UpdateRelaunchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(UpdateRelaunch.consume(defaults))
        UpdateRelaunch.mark(defaults)
        XCTAssertTrue(UpdateRelaunch.consume(defaults))
        XCTAssertFalse(UpdateRelaunch.consume(defaults))
    }

    // 1.0.3以前のON/OFFを引き継ぐ。ONは画面共有中も見えるトーストへ移し、OFFの意思は代替表示で迂回しない
    func testLegacyCopyNotificationPreferenceMigrates() throws {
        let off = try JSONDecoder().decode(OCRSettings.self, from: Data(#"{"notifyOnCopy":false}"#.utf8))
        XCTAssertEqual(off.copyFeedback, .none)
        let on = try JSONDecoder().decode(OCRSettings.self, from: Data(#"{"notifyOnCopy":true,"notificationPreview":true}"#.utf8))
        XCTAssertEqual(on.copyFeedback, .toast)
        XCTAssertTrue(on.notificationPreview)
        var chosen = OCRSettings(); chosen.copyFeedback = .notification
        XCTAssertEqual(try JSONDecoder().decode(OCRSettings.self, from: JSONEncoder().encode(chosen)).copyFeedback, .notification)
    }

    // トーストか「表示しない」を選んだ場合はmacOSの通知を出さない。バナーが表示される環境での重複を防ぐ
    func testOnlyNotificationModePostsSystemNotification() {
        for feedback in [CopyFeedback.toast, .none] {
            var settings = OCRSettings(); settings.copyFeedback = feedback
            var delivery: CopyNotification.Delivery?
            CopyNotification.deliver(text: "private fixture", settings: settings) { delivery = $0 }
            XCTAssertEqual(delivery, .disabled)
        }
    }

    func testNotificationContentPreviewIsOptInAndBounded() {
        let secret = String(repeating: "private", count: 80)
        let normal = CopyNotification.content(text: secret, preview: false)
        XCTAssertEqual(normal.title, "コピーしました")
        XCTAssertFalse(normal.body.contains("private"))
        XCTAssertEqual(CopyNotification.content(text: secret, preview: true).body.count, 160)
    }

    func testNativeCopyRequestsReuseIdentifierWithLatestContent() {
        let first = CopyNotification.successRequest(text: "first", preview: false)
        let second = CopyNotification.successRequest(text: "second", preview: true)
        XCTAssertEqual(first.identifier, second.identifier)
        XCTAssertEqual(second.content.body, "second")
        XCTAssertFalse(first.content.body.contains("first"))
        XCTAssertNil(second.trigger)
    }

    func testCopyFeedbackUsesExactlyOneDeliveryPath() {
        XCTAssertFalse(CopyNotification.shouldShowFallback(for: .delivered, notificationsEnabled: true))
        XCTAssertFalse(CopyNotification.shouldShowFallback(for: .disabled, notificationsEnabled: true))
        XCTAssertTrue(CopyNotification.shouldShowFallback(for: .permissionMissing, notificationsEnabled: true))
        XCTAssertTrue(CopyNotification.shouldShowFallback(for: .failed, notificationsEnabled: true))
        let deliveries: [CopyNotification.Delivery] = [.disabled, .delivered, .permissionMissing, .failed]
        for delivery in deliveries {
            XCTAssertFalse(CopyNotification.shouldShowFallback(for: delivery, notificationsEnabled: false))
        }
    }

    func testNativeCopyNotificationUsesStandardPriorityAndIsSilent() {
        let content = CopyNotification.successRequest(text: "private fixture", preview: false).content
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertNil(content.sound)
        XCTAssertFalse(content.body.contains("private fixture"))
    }

    func testToastDoesNotReceiveOCRBodyEvenWhenCenterPreviewIsEnabled() {
        let secret = "private fixture"
        XCTAssertEqual(CopyNotification.content(text: secret, preview: true).body, secret)
        let toast = ToastMessage.copied()
        XCTAssertEqual(toast.title, "コピーしました")
        XCTAssertFalse(toast.title.contains(secret))
    }

    func testSuccessToastCoalescesWithoutTakingKeyOrMainWindow() {
        let presenter = ToastPresenter()
        defer { presenter.hide() }
        let previousKey = NSApp.keyWindow
        presenter.show(.copied())
        presenter.show(.copied())
        let panels = NSApp.windows.filter { $0.isVisible && $0.frame.width == 330 && $0.frame.height == 54 }
        XCTAssertEqual(panels.count, 1)
        XCTAssertFalse(panels.first?.canBecomeKey ?? true)
        XCTAssertFalse(panels.first?.canBecomeMain ?? true)
        XCTAssertTrue(NSApp.keyWindow === previousKey)
    }

    func testSyntheticCodexLive() throws {
        guard ProcessInfo.processInfo.environment["SCREEN_TEXT_CAPTURE_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Explicitly enable synthetic subscription test; normal tests are offline.")
        }
        let workspace = try syntheticImage()
        var settings = OCRSettings(); settings.backend = .codex
        let result = try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: Cancellation())
        XCTAssertTrue(result.contains("SCREEN TEXT 2026"), result)
        XCTAssertTrue(result.contains("画面の文字をコピー"), result)
    }

    private func syntheticImage(text: String = "SCREEN TEXT 2026\n画面の文字をコピー") throws -> OCRWorkspace {
        let workspace = try OCRWorkspace()
        let image = NSImage(size: NSSize(width: 900, height: 240))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 240).fill()
        (text as NSString).draw(in: NSRect(x: 36, y: 30, width: 830, height: 180),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: workspace.image)
        return workspace
    }

    private func fakeCLI(workspace: OCRWorkspace, mode: String) throws -> String {
        let path = workspace.directory.appendingPathComponent(mode)
        let script = #"""
        #!/usr/bin/python3
        import json, sys, os
        mode = os.path.basename(sys.argv[0])
        with open(sys.argv[0] + '.calls', 'a') as log: log.write(' '.join(sys.argv[1:3]) + '\n')
        if sys.argv[1:3] == ['app-server', 'generate-json-schema']:
            out = os.path.join(sys.argv[sys.argv.index('--out') + 1], 'v2')
            os.makedirs(out, exist_ok=True)
            note = 'Selected environments.' if mode.endswith('oldschema') else 'Empty disables environment access.'
            for name in ['ThreadStartParams', 'TurnStartParams']:
                with open(os.path.join(out, name + '.json'), 'w') as f: json.dump({'properties': {'environments': {'description': note}}}, f)
            sys.exit()
        if '--version' in sys.argv:
            print('2.1.112 (Claude Code)' if mode.startswith('claude') else 'codex-cli 0.142.5'); sys.exit()
        if sys.argv[1:3] == ['auth', 'status']:
            logged_in = mode == 'claude-success'
            print(json.dumps({'loggedIn': logged_in, 'authMethod': 'claude.ai' if logged_in else 'none', 'apiProvider': 'firstParty'})); sys.exit(0 if logged_in else 1)
        if mode == 'claude-success':
            assert sys.argv[sys.argv.index('--tools') + 1] == ''
            assert json.loads(sys.argv[sys.argv.index('--settings') + 1])['fastMode'] is False
            for line in sys.stdin:
                request = json.loads(line)
                if request['type'] == 'control_request':
                    assert request['request']['skills'] == []
                    print(json.dumps({'type': 'control_response', 'response': {'request_id': request['request_id'], 'subtype': 'success', 'response': {'models': [{'value': 'sonnet', 'displayName': 'Sonnet'}]}}}), flush=True)
                else:
                    assert sys.argv[sys.argv.index('--model') + 1] == 'sonnet'
                    assert request['message']['content'][1]['source']['media_type'] == 'image/png'
                    print(json.dumps({'type': 'system', 'subtype': 'init', 'tools': []}), flush=True)
                    print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'SCREEN TEXT 2026'}), flush=True)
            sys.exit()
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if method == 'initialized': continue
            result = {}
            if method == 'account/read': result = {'account': None if mode.endswith('logged-out') else {'type': 'chatgpt'}}
            if method == 'model/list': result = {'data': [{'model': 'fixture-image', 'displayName': 'Fixture', 'inputModalities': ['text', 'image'], 'isDefault': True, 'serviceTiers': [{'id': 'priority', 'name': 'Fast'}]}], 'nextCursor': None}
            if method == 'thread/start':
                assert request['params']['environments'] == []
                assert request['params']['ephemeral'] is True
                assert request['params']['serviceTier'] == ('priority' if mode.endswith('fast') else None)
                result = {'thread': {'id': 'test', 'environments': ['unexpected'] if mode.endswith('env') else []}}
            if method == 'turn/start':
                assert request['params']['environments'] == []
                assert request['params']['input'][1]['url'].startswith('data:image/png;base64,')
                result = {'turn': {'id': 'turn'}}
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
            if method == 'turn/start':
                if mode.endswith('rate'):
                    print(json.dumps({'method': 'turn/completed', 'params': {'turn': {'status': 'failed', 'error': {'message': 'usage limit reached'}}}}), flush=True)
                else:
                    item = {'type': 'commandExecution'} if mode.endswith('tool') else {'type': 'agentMessage', 'text': 'SCREEN TEXT 2026', 'phase': 'final_answer'}
                    print(json.dumps({'method': 'item/completed', 'params': {'item': item}}), flush=True)
                    print(json.dumps({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}}), flush=True)
        """#
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }
}
