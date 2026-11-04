import XCTest
import Combine
import AppKit
@testable import screentextcapture

final class AvailabilityTests: XCTestCase {
    func testSettingsActionShowsProgressAndCompletesEveryAttemptOnMainThread() {
        let count = LockedCount()
        let checker = AvailabilityChecker(minimumDisplayTime: 0.02) { _, _, progress in
            count.increment(); progress("認識言語を確認しています…")
            return self.result("Apple Vision：利用可能")
        }
        let model = AppModel(settings: OCRSettings(), checker: checker)
        let completed = expectation(description: "first completion")
        var subscription = model.$availabilityState.sink { state in
            XCTAssertTrue(Thread.isMainThread)
            if state.phase == .available { completed.fulfill() }
        }
        model.checkAvailability()
        XCTAssertTrue(model.isChecking)
        XCTAssertTrue(model.availabilityState.message.contains("確認しています"))
        model.checkAvailability()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(count.value, 1)
        XCTAssertNotNil(model.availabilityState.checkedAt)
        let firstDate = model.availabilityState.checkedAt!
        subscription.cancel()
        let repeated = expectation(description: "manual retry completes")
        subscription = model.$availabilityState.dropFirst().sink { if $0.phase == .available { repeated.fulfill() } }
        model.checkAvailability()
        XCTAssertTrue(model.isChecking)
        wait(for: [repeated], timeout: 2)
        XCTAssertEqual(count.value, 2)
        XCTAssertGreaterThan(model.availabilityState.checkedAt!, firstDate)
        subscription.cancel()
    }

    func testTimeoutStopsProgressAndAllowsRetryWithoutLateResult() {
        let count = LockedCount()
        let cancelled = expectation(description: "timed out worker stops")
        let checker = AvailabilityChecker(timeout: 0.05, minimumDisplayTime: 0) { _, token, _ in
            count.increment()
            if count.value == 1 {
                while !token.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                cancelled.fulfill()
                try token.check()
            }
            return self.result("retry succeeded")
        }
        let timedOut = expectation(description: "visible timeout")
        var subscription = checker.$state.sink { if $0.phase == .unavailable { timedOut.fulfill() } }
        checker.start(settings: OCRSettings())
        wait(for: [timedOut, cancelled], timeout: 2)
        XCTAssertFalse(checker.state.isChecking)
        XCTAssertTrue(checker.state.message.contains("タイムアウト"))
        subscription.cancel()
        let retried = expectation(description: "retry result")
        subscription = checker.$state.sink { if $0.phase == .available { retried.fulfill() } }
        XCTAssertTrue(checker.start(settings: OCRSettings()))
        wait(for: [retried], timeout: 2)
        XCTAssertEqual(checker.state.message, "retry succeeded")
        subscription.cancel()
    }

    func testBackendChangeRejectsOldCompletionAndOldProgress() {
        let oldStarted = expectation(description: "old backend starts")
        let checker = AvailabilityChecker(minimumDisplayTime: 0) { settings, _, progress in
            if settings.backend == .codex {
                oldStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.12)
                progress("old progress")
                return self.result("old", model: "old")
            }
            return self.result("new", model: "new")
        }
        var settings = OCRSettings(); settings.backend = .codex
        let model = AppModel(settings: settings, checker: checker)
        model.checkAvailability()
        wait(for: [oldStarted], timeout: 2)
        let current = expectation(description: "new backend completes")
        let subscription = model.$availabilityState.sink { if $0.phase == .available { current.fulfill() } }
        model.settings.backend = .claude
        model.recheckAvailability()
        wait(for: [current], timeout: 2)
        let stale = expectation(description: "old result remains discarded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(model.models.map(\.id), ["new"])
            XCTAssertEqual(model.availabilityState.message, "new")
            stale.fulfill()
        }
        wait(for: [stale], timeout: 2)
        subscription.cancel()
    }

    func testCancellationAndBusyStateNeverStartAnotherWorker() {
        let stopped = expectation(description: "cancel worker")
        let count = LockedCount()
        let checker = AvailabilityChecker(timeout: 2, minimumDisplayTime: 0) { _, token, _ in
            count.increment()
            while !token.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            stopped.fulfill(); try token.check()
            return self.result("unreachable")
        }
        let model = AppModel(settings: OCRSettings(), checker: checker)
        model.isBusy = true; model.checkAvailability()
        XCTAssertFalse(model.isChecking); XCTAssertEqual(count.value, 0)
        model.isBusy = false; model.checkAvailability()
        XCTAssertTrue(model.isChecking)
        checker.cancel()
        XCTAssertFalse(model.isChecking)
        XCTAssertTrue(model.availabilityState.message.contains("中止"))
        wait(for: [stopped], timeout: 2)
        XCTAssertNil(model.availabilityState.discovery)
    }

    func testAuthenticationFailureIsVisibleAndNeverReportsSuccess() {
        let checker = AvailabilityChecker(minimumDisplayTime: 0) { _, _, _ in throw OCRError.loginRequired("Claude Code") }
        var settings = OCRSettings(); settings.backend = .claude
        let model = AppModel(settings: settings, checker: checker)
        let failed = expectation(description: "failure visible")
        let subscription = model.$availabilityState.sink { if $0.phase == .unavailable { failed.fulfill() } }
        model.checkAvailability(); wait(for: [failed], timeout: 2)
        XCTAssertTrue(model.availabilityState.message.contains("ログイン"))
        XCTAssertFalse(model.isChecking); XCTAssertTrue(model.models.isEmpty)
        subscription.cancel()
    }

    func testLoadingAndCheckingPreserveExistingFastPreferenceWithoutGrantingConsent() {
        var settings = OCRSettings(); settings.backend = .codex; settings.codexFast = true
        let checker = AvailabilityChecker(minimumDisplayTime: 0) { _, _, _ in self.result("read only") }
        let model = AppModel(settings: settings, checker: checker)
        XCTAssertTrue(model.settings.codexFast); XCTAssertFalse(model.settings.fastCostConsent)
        let completed = expectation(description: "read only completion")
        let subscription = model.$availabilityState.sink { if $0.phase == .available { completed.fulfill() } }
        model.checkAvailability(); wait(for: [completed], timeout: 2)
        XCTAssertEqual(model.settings, settings)
        model.setFastMode(false)
        XCTAssertFalse(model.settings.fastMode); XCTAssertFalse(model.settings.fastCostConsent)
        model.setFastMode(true)
        XCTAssertTrue(model.settings.fastMode); XCTAssertTrue(model.settings.fastCostConsent)
        subscription.cancel()
    }

    func testEmptyModelListDoesNotReportAvailable() throws {
        let workspace = try OCRWorkspace()
        var settings = OCRSettings(); settings.backend = .codex
        settings.codexPath = try fixture(workspace: workspace, mode: "codex-no-models")
        XCTAssertThrowsError(try ModelDiscovery.discover(settings: settings, workspace: workspace.directory)) {
            XCTAssertEqual($0 as? OCRError, .unavailableModel)
        }
    }

    func testCodexDiscoveryUsesOneAuthenticatedSessionWithoutInference() throws {
        let workspace = try OCRWorkspace()
        var settings = OCRSettings(); settings.backend = .codex
        settings.codexPath = try fixture(workspace: workspace, mode: "codex-ready")
        var stages = [String]()
        let discovered = try ModelDiscovery.discover(settings: settings, workspace: workspace.directory) { stages.append($0) }
        XCTAssertEqual(discovered.models.map(\.id), ["fixture-image"])
        XCTAssertTrue(discovered.status.contains("ログイン確認済み"))
        XCTAssertEqual(stages.count, 4)
        let events = try String(contentsOf: workspace.directory.appendingPathComponent("events"), encoding: .utf8)
        XCTAssertEqual(events.components(separatedBy: "app-server-start").count - 1, 1)
        XCTAssertEqual(events.components(separatedBy: "account/read").count - 1, 1)
        XCTAssertFalse(events.contains("thread/start")); XCTAssertFalse(events.contains("turn/start"))
    }

    func testDiscoveryDistinguishesMissingCLIAndLoggedOutAccounts() throws {
        for backend in [OCRBackend.codex, .claude] {
            let workspace = try OCRWorkspace()
            var settings = OCRSettings(); settings.backend = backend
            let path = try fixture(workspace: workspace, mode: backend == .codex ? "codex-logged-out" : "claude-logged-out")
            settings.codexPath = path; settings.claudePath = path
            XCTAssertThrowsError(try ModelDiscovery.discover(settings: settings, workspace: workspace.directory)) {
                XCTAssertEqual($0 as? OCRError, .loginRequired(backend == .codex ? "Codex CLI" : "Claude Code"))
            }
            settings.codexPath = "/does-not-exist/codex"; settings.claudePath = "/does-not-exist/claude"
            XCTAssertThrowsError(try ModelDiscovery.discover(settings: settings, workspace: workspace.directory)) {
                guard case .missingCLI = $0 as? OCRError else { return XCTFail("Expected a missing CLI error") }
            }
        }
    }

    func testClaudeCandidatesAndUnsupportedVisionLanguage() throws {
        let workspace = try OCRWorkspace()
        var settings = OCRSettings(); settings.backend = .claude
        settings.claudePath = try fixture(workspace: workspace, mode: "claude-ready")
        let found = try ModelDiscovery.discover(settings: settings, workspace: workspace.directory)
        XCTAssertEqual(found.models.map(\.id), ["sonnet"])
        XCTAssertFalse(found.fastSupported)
        settings.backend = .vision; settings.languages = ["not-a-language"]
        XCTAssertThrowsError(try ModelDiscovery.discover(settings: settings, workspace: workspace.directory)) {
            XCTAssertEqual($0 as? OCRError, .invalidLanguage("not-a-language"))
        }
    }

    private func result(_ status: String, model: String? = nil) -> BackendDiscovery {
        BackendDiscovery(status: status, models: model.map { [OCRModel(id: $0, name: $0)] } ?? [], fastSupported: false, fastReason: "")
    }

    private func fixture(workspace: OCRWorkspace, mode: String) throws -> String {
        let path = workspace.directory.appendingPathComponent(mode)
        let code = #"""
        #!/usr/bin/python3
        import sys, os, json
        mode = os.path.basename(sys.argv[0])
        def event(value):
            with open('events', 'a') as file: file.write(value + '\n')
        if '--version' in sys.argv:
            print('2.1.112 (Claude Code)' if mode.startswith('claude') else 'codex-cli 0.142.5'); sys.exit()
        if 'generate-json-schema' in sys.argv:
            directory = sys.argv[sys.argv.index('--out') + 1] + '/v2'
            os.makedirs(directory, exist_ok=True)
            for name in ['ThreadStartParams', 'TurnStartParams']:
                with open(directory + '/' + name + '.json', 'w') as file:
                    json.dump({'properties': {'environments': {'description': 'Empty disables environment access.'}}}, file)
            sys.exit()
        if sys.argv[1:3] == ['auth', 'status']:
            logged_in = mode == 'claude-ready'
            print(json.dumps({'loggedIn': logged_in, 'authMethod': 'claude.ai' if logged_in else 'none', 'apiProvider': 'firstParty'})); sys.exit(0 if logged_in else 1)
        event('app-server-start')
        for line in sys.stdin:
            request = json.loads(line)
            if mode == 'claude-ready':
                assert request['type'] == 'control_request', 'Availability must not send a user prompt'
                print(json.dumps({'type': 'control_response', 'response': {'request_id': request['request_id'], 'subtype': 'success', 'response': {'models': [{'value': 'sonnet', 'displayName': 'Sonnet'}]}}}), flush=True)
                continue
            method = request.get('method')
            if method == 'initialized': continue
            assert method in ['initialize', 'account/read', 'model/list'], 'Availability must not start inference'
            event(method)
            result = {}
            if method == 'account/read': result = {'account': None if mode.endswith('logged-out') else {'type': 'chatgpt'}}
            if method == 'model/list': result = {'data': [] if mode == 'codex-no-models' else [{'model': 'fixture-image', 'displayName': 'Fixture', 'inputModalities': ['image'], 'isDefault': True}], 'nextCursor': None}
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """#
        try code.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }
}

private final class LockedCount {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
