import Foundation
import Combine

struct AvailabilityState {
    enum Phase { case idle, checking, available, unavailable }
    var phase: Phase = .idle
    var message = "利用可否を確認してください。"
    var checkedAt: Date?
    var discovery: BackendDiscovery?
    var isChecking: Bool { phase == .checking }
}

/// Every attempt has one deadline and generation. Late results cannot overwrite a new backend.
final class AvailabilityChecker: ObservableObject {
    typealias Discovery = (OCRSettings, Cancellation, @escaping (String) -> Void) throws -> BackendDiscovery
    @Published private(set) var state = AvailabilityState()
    private let discover: Discovery
    private let timeout: TimeInterval
    private let minimumDisplayTime: TimeInterval
    private var generation: UUID?
    private var cancellation: Cancellation?
    private var deadline: DispatchWorkItem?

    init(timeout: TimeInterval = 30, minimumDisplayTime: TimeInterval = 0.35,
         discover: @escaping Discovery = { settings, cancellation, progress in
             let workspace = try OCRWorkspace()
             defer { workspace.remove() }
             return try ModelDiscovery.discover(settings: settings, workspace: workspace.directory,
                                                cancellation: cancellation, progress: progress)
         }) {
        self.timeout = timeout
        self.minimumDisplayTime = minimumDisplayTime
        self.discover = discover
    }

    @discardableResult
    func start(settings: OCRSettings) -> Bool {
        precondition(Thread.isMainThread)
        guard !state.isChecking else { return false }
        let id = UUID(), token = Cancellation(), started = Date()
        generation = id
        cancellation = token
        // 設定画面では認識方法の選択欄のすぐ下に出すため、方法名は前置しない
        state = AvailabilityState(phase: .checking, message: "確認しています…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == id else { return }
            token.cancel()
            self.finish(.failure(OCRError.timeout), id: id)
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        let discovery = discover
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try discovery(settings, token) { stage in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, self.state.isChecking else { return }
                    self.state.message = stage
                }
            } }
            let delay = max(0, (self?.minimumDisplayTime ?? 0) - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finish(result, id: id)
            }
        }
        return true
    }

    func cancel(message: String = "確認を中止しました。再確認できます。") {
        precondition(Thread.isMainThread)
        cancellation?.cancel()
        cancellation = nil
        generation = nil
        deadline?.cancel()
        deadline = nil
        state = AvailabilityState(message: message)
    }

    private func finish(_ result: Result<BackendDiscovery, Error>, id: UUID) {
        guard generation == id else { return }
        deadline?.cancel()
        deadline = nil
        generation = nil
        cancellation = nil
        switch result {
        case .success(let discovery):
            state = AvailabilityState(phase: .available, message: discovery.status, checkedAt: Date(), discovery: discovery)
        case .failure(let error):
            let reason: String
            switch error as? OCRError {
            case .timeout:
                reason = "\(Int(timeout))秒で確認がタイムアウトしました。接続とCLIを確認して再確認してください。"
            case .invalidResponse:
                reason = "CLIから認証・モデル情報を取得できませんでした。再確認してください。"
            case .some(let known): reason = known.localizedDescription
            case .none: reason = "確認に失敗しました。CLIのパスと接続を確認して再確認してください。"
            }
            state = AvailabilityState(phase: .unavailable, message: reason, checkedAt: Date())
        }
    }

    deinit { cancellation?.cancel(); deadline?.cancel() }
}
