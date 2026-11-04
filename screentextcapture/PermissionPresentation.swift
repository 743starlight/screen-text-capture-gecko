import Foundation

enum PermissionKind: Equatable {
    case screenCapture, notifications

    func isGranted(screenCapture: Bool, notifications: Bool) -> Bool {
        self == .screenCapture ? screenCapture : notifications
    }

    var title: String {
        switch self {
        case .screenCapture: return "画面収録の許可が必要です"
        case .notifications: return "通知が許可されていません"
        }
    }

    var explanation: String {
        switch self {
        case .screenCapture:
            return "選択した画面の画像から文字を読み取るために、画面収録の許可が必要です。音声の録音やアクセシビリティの許可は必要ありません。\n\nシステム設定 → プライバシーとセキュリティ → 画面収録（OSによっては「画面とシステムオーディオの録音」）でScreenTextCapture Geckoを許可してください。変更後はアプリの再起動が必要な場合があります。"
        case .notifications:
            return "通知センターにコピー成功を表示するには、通知の許可が必要です。通知が未許可でも文字のコピーは利用できます。\n\n未設定なら「通知の許可を要求」を選びます。すでに拒否した場合は、システム設定 → 通知 → ScreenTextCapture Geckoで「通知を許可」を有効にしてください。"
        }
    }

    var settingsURL: URL {
        switch self {
        case .screenCapture: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
    }

    var requestTitle: String { self == .screenCapture ? "画面収録の許可を要求" : "通知の許可を要求" }
}

/// Suppress duplicate sheets and queued key repeats. Dismissal never starts another operation.
final class PermissionPromptGate {
    private(set) var isPresented = false
    private var dismissedAt = Date.distantPast

    func begin(now: Date = Date()) -> Bool {
        guard !isPresented, now.timeIntervalSince(dismissedAt) >= 1 else { return false }
        isPresented = true
        return true
    }

    func finish(now: Date = Date()) {
        isPresented = false
        dismissedAt = now
    }
}
